package ZmMailSummary::Command::provide;
use Mojo::Base 'Mojolicious::Command';

use Getopt::Long 2.25 qw(:config posix_default no_ignore_case);
use IO::Handle;
use Carp;
use FindBin;
use Mojo::JSON qw(decode_json);
use Mojo::File;
use Mojo::DOM;
use Data::Processor;
use Encode;
use Time::Piece;
use Time::Seconds;
use Time::Local;
use Email::MIME;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP qw();
binmode (STDOUT, ':utf8');
binmode (STDERR, ':utf8');

=head1 NAME

ZmMailSummary::Command::provide - provide a summary of new mail in a folder by sending mail to each user.

=head1 SYNOPSIS

    zmMailSummary provide

    options:
        -n | --noaction don't send mails.
        -v | --verbose  be very noisy
        -d | --debug    print debug messages
        -f | --force    send mails even if already sent today
        --account-names a regex; send only to names matching


=head1 DESCRIPTION

whatever

=cut

has description => 'send a summary mail to each user with mails in the given folder (spam, e.g.)';
has usage => sub { shift->extract_usage };

my %opt;
my $say = sub{
    my $msg = shift;
    print "***verbose: $msg\n" if $opt{verbose} or $opt{debug};
};

my $debug = sub{
    my $msg = shift;
    print "***debug: $msg\n" if $opt{debug};
};

sub run {
    my $self = shift;
    local @ARGV = @_;
    GetOptions(\%opt, 'noaction|no-action|n', 'debug|d', 'verbose|v', 'account-names=s', 'force|f')
        or exit(1);
    if ($opt{noaction}) {
        $opt{verbose} = 1 ;
        warn "*** NO ACTION MODE ***\n";
    }

    croak "$0 only works when running as user 'zimbra'"
        unless ($ENV{USER} eq 'zimbra');

    # read settings
    my $settings = _read_settings();
    my @excludes = _read_exclude_file($settings);

    # get accounts
    my $zmProv = zmProv->new(
        noaction=>$opt{noaction},
        verbose=>$opt{verbose},
        debug=>$opt{debug}
    );
    my @accounts = grep /\@/, split /\n/, $zmProv->cmd('gaa') ;

    my $box = zmMailBox->new(verbose=>$opt{verbose},noaction=>$opt{noaction},debug=>$opt{debug});

    for my $account (@accounts){
        $opt{'account-names'} && do {
            $account =~ /$opt{'account-names'}/ || do {
                $debug->("skip $account, does not match $opt{'account-names'}");
                next;
            }
        };

        next if _in_list($account, @excludes);

        # the MailboxManager tool sets amavisBlacklistSender: $settings->{unsubscribe}
        my @blacklist = grep /amavisBlacklistSender:.*$settings->{unsubscribe}/, split /\n/, $zmProv->cmd("ga $account");
        @blacklist && do {
            say "skip $account (has option set in Mailmanager)";
            next;
        };

        # change to account
        $box->cmd("sm $account");

        my $send_to = $account;
        $send_to =~ s/$settings->{change_to_address}[0]/$settings->{change_to_address}[1]/
            if $settings->{change_to_address};

        # check folder found
        my $folder_found = 0;
        for my $line (split /\n/, $box->cmd("getAllFolders")){
            # the line for the folder looks like
            # 4  mess           1           1  /Junk
            next unless $line =~ m|mess.+/$settings->{folder}\s*$|;
            $folder_found = 1;
        }
        unless ($folder_found){
            print "*** $account: no folder $settings->{folder}\n";
            next;
        }

        # read all messages
        # report -x days until yesterday
        my $t = localtime;
        my $before = timelocal(0,0,0, $t->mday, $t->mon-1, $t->year)*1000; # millisecs for zmmailbox
        $t -= ONE_DAY for (1..$settings->{report_back_days});
        my $after = timelocal(0,0,0, $t->mday, $t->mon-1, $t->year)*1000-1;
        # fetch the first messages
        my @lines = split /\n/, $box->cmd("search --types message 'in:/$settings->{folder} after:$after before:$before'");
        my @msgs; # array of hashes [{from => foo@bar.com, date => 01/25/17, msg => whatever, I mailed it}]
        while (@lines){
            my $line = shift @lines;
            $say->($line);
            $line =~ /more:\s+true/ && do {
                push @lines, split(/\n/, $box->cmd('search --next'));
                next;
            };

            # a line with a message:
            # no id    type   sender  subject    date / time
            # 1. 1726  mess   foo@bar whatnot    02/15/17 16:25
            $line =~ /^\s*\d+\.\s+(\d+)\s+mess\s+(.*)$/ && do {
                my $id = $1;
                my $rest = $2;

                # chomp date off the end
                $rest =~ s{(\d+)/(\d+)/(\d+)\s+(\d+):(\d+)\s*$}{};
                my $month = $1;
                my $day   = $2;
                my $year  = $3;
                my $hour  = $4;
                my $min   = $5;

                # byte sender off the start
                $rest =~ s/^\s*([\w\@]+)\s+//;
                my $from = $1;

                my $subject = $rest;
                $subject =~ s/\s*$//;

                push @msgs, {
                    url     => "$settings->{zimbra_url}/?id=$id",
                    from    => decode('UTF-8', $from),
                    subject => decode('UTF-8', $subject),
                    date    => "$day.$month.$year $hour:$min"
                };
            };

        }

        if (scalar(@msgs) > 0){
            # user locale
            my $user_locale = _get_user_locale($zmProv, $account, $settings);

            # load templates
            # this should never fail because we check file existence during config validation
            my %path = (
                txt => Mojo::File->new(
                    "$FindBin::RealBin/../templates/mail_template_$user_locale.txt.ep"),
                html => Mojo::File->new(
                    "$FindBin::RealBin/../templates/mail_template_$user_locale.html.ep")
            );
            my $r = {
                user => $account,
                report_back_days => $settings->{report_back_days},
                mails_number => scalar(@msgs),
                msgs => \@msgs,
            };

            my $template = '% my $r = shift;'."\n".
                '% my $user = $r->{user};'."\n".
                '% my $report_back_days = $r->{report_back_days};'."\n".
                '% my $mails_number = $r->{mails_number};'."\n".
                '% my @msgs = @{$r->{msgs}};'."\n";

            say "send account: '$account' to: '$send_to'";

            $opt{noaction} && do {
                say "noaction: skip sending";
                next;
            };

            # TODO get timestamp "last send time" from LDAP:
            # matthias_test_1@zimbra.oetiker.ch +zimbraZimletUserProperties "ch_oep_test:irgendwas beliebiges"
            # zmprov ga matthias_test_1@zimbra.oetiker.ch |grep ch_oep
            # zimbra@wartburg:~$ zmprov ga  |grep ch_oep
            # zimbraZimletUserProperties: ch_oep_test:favouriteFood:chocolate
            # zimbraZimletUserProperties: ch_oep_test:irgendwas beliebiges

            # send mail

            # extract subject: from html template (1st line)
            my $html = Mojo::Template->new->render($template.decode('UTF-8', $path{html}->slurp), $r);
            $html =~ s/^Subject: (.*)//;
            my $subject = $1;

            my $txt_body = Email::MIME->create(
                attrbutes => {
                    content_type => 'text/plain',
                    charset      => 'UTF-8',
                    encoding     => 'Quoted-printable',
                },
                body => encode('UTF-8', Mojo::Template->new->render(
                    $template.decode('UTF-8', $path{txt}->slurp), $r))
            );

            # need to render template first, then replace img tags.
            # dom renderer otherwise changes template substitutions in tags, to tags
            my $dom = Mojo::DOM->new($html);
            $dom->find('img')->each(sub {
                return if $_->{src} =~ /^http/; # only rewrite inlined images
                $_->replace("<img src=\"cid:$_->{src}\"/>")
            });
            $html = $dom->to_string;
            # prepend DOCTYPE
            $html = '<!DOCTYPE HTML PUBLIC "-//W3C//DTD XHTML 1.0 Transitional //EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">'.$html;

            my $html_body = Email::MIME->create(
                attributes => {
                    content_type => 'text/html',
                    charset      => 'UTF-8',
                    encoding     => 'Quoted-printable',
                },
                body => encode('UTF-8', $html)
            );

            my @attachments = ();
            Mojo::DOM->new($path{html}->slurp)->find('img')->each(sub {
                my $src = $_->{src}; # file name is in the src tag
                return if $src =~ /^http/; # only inline local images
                $src =~ /\.(\w+)$/;

                push @attachments, Email::MIME->create(
                    attributes => {
                        content_type => "image/$1",
                        encoding     => 'base64',
                        disposition  => qq{inline; filename="$src"\nContent-ID: $src},
                    },
                    body => Mojo::File->new("$FindBin::RealBin/../templates/$src")->slurp
                );
            });

            my $email = Email::MIME->create(
                header_str => [
                    From           => $settings->{mail_from},
                    To             => $send_to,
                    Subject        => $subject,
                    'Content-Type' => 'multipart/related'
                ],
                parts => [
                    Email::MIME->create (
                        attributes => {
                            content_type => 'multipart/alternative'
                        },
                        parts => [
                            $txt_body,
                            $html_body
                        ]
                    ),
                    @attachments
                ]
            );

            eval {
                sendmail (
                    $email,
                    {
                        from => $settings->{mail_from},
                        transport => Email::Sender::Transport::SMTP->new({
                            host => $settings->{mail_server}
                        })
                    }
                );
                $debug->($email->as_string);
            };
            $@ && do {
                warn "sending failed $@";
            }

        }
        else {
            say "skip $account: no mails in $settings->{folder} in the last $settings->{report_back_days} days";
        }
    }
}

sub _get_user_locale{
    my $zmProv = shift;
    my $account = shift;
    my $settings = shift;
    my @user_locale_lines = grep /zimbraPrefLocale/i, split /\n/, $zmProv->cmd("ga $account");
    $debug->("-- $account --");
    $user_locale_lines[0] =~ /: (.*)$/;
    # default to default_language if not set or not in our list of available languages
    my $user_locale = $1 // $settings->{default_language};
    $user_locale = $settings->{default_language}
        unless _in_list($user_locale, @{$settings->{available_languages}});
    $debug->("locale: $1");
    return $user_locale;
}

sub _read_settings{
    open my $sh, '<', "$FindBin::RealBin/../etc/zmmailsummary.cfg" or die $!;
    my $json_str;
    while (<$sh>){
        chomp;
        $json_str .= $_;
    }
    my $settings = decode_json $json_str;
    my $schema = {
        GENERAL => {
            members => {
                folder => {
                    description => 'the Zimbra mail folder'
                },
                exclude_file => {
                    description => 'file with a list of addresses to skip',
                    validator => sub {
                        my $value = shift;
                        return undef if -f "$FindBin::RealBin/../$value";
                        return "file $value does not exist";
                    }
                },
                mail_server => {
                    description => 'the mail server you want to send mails through',
                },
                mail_from => {
                    description => 'what should be shown in the "From:"'
                },
                change_to_address => {
                    description => 'regex replacment for "To:". a no-op if empty',
                    validator => sub {
                        my $value = shift;
                        return undef unless $value; # empty value ok.
                        return 'please supply an array with 2 values'
                            unless ref($value) eq 'ARRAY' and scalar(@{$value} == 2);
                        return undef;
                    }
                },
                report_back_days => {
                    description => 'e.g. setting this to 1 reports mails from yesterday'
                },
                zimbra_url => {
                    description => 'URL of your zimbra-web',
                    value => qr{https?://.+}
                },
                default_language => {
                    description => 'default language, e.g. "de", "it" or "en_US"'
                },
                available_languages => {
                    description => 'languages with a template. Naming scheme: "temlpates/mail_template_(locale).txt.ep", e.g. "templates/mail_template_fr_FR.txt.ep"',
                    validator => sub {
                        my $lang = shift;
                        return "please supply an array" unless ref $lang eq "ARRAY";
                        my @errors;
                        for my $l (@{$lang}){
                            for my $type ('txt', 'html'){
                                my $f = "$FindBin::RealBin/../templates/mail_template_$l.$type.ep";
                                push @errors, "$f not found" unless -f $f;

                                next unless $type eq 'html';
                                Mojo::DOM->new(Mojo::File->new($f)->slurp)
                                    ->find('img')->each(
                                        sub {
                                            # only check inlined images
                                            return if $_->{src} =~ /^http/;
                                            my $src = "$FindBin::RealBin/../templates/".$_->{src};
                                            push @errors, "referenced img $src not found ($f)"
                                                unless -f "$src"
                                        }
                                );
                                push @errors, "html template $f does not start with 'Subject:' on first line"
                                    unless Mojo::File->new($f)->slurp =~ /^Subject:/;
                            }
                        }
                        return "\n". join "\n", @errors if @errors;
                        return undef;
                    }
                },
                unsubscribe => {
                    description => 'user can enter this "mail address" in preferences -> blacklist to not receive our mail',
                }
            }
        }
    };
    my $errors = Data::Processor->new($schema)->validate($settings);
    if ($errors->count > 0){
        say join "\n", $errors->as_array();
        exit;
    }
    return $settings->{GENERAL};
}

sub _read_exclude_file{
    my $settings = shift;
    open my $xh, '<', "$FindBin::RealBin/../$settings->{exclude_file}" or die $!;
    my @excludes;
    while (<$xh>){
        chomp;
        s/^\s*//;
        s/\s*$//;
        next if /^\s*$/;
        push @excludes, $_;
    }
    return @excludes;
}

sub _in_list{
    my $item = shift;
    my @array = @_;

    for (@array){
        /$item/ && do {
            $debug->("$item found in list");
            return 1;
        }
    }
    return 0;
}

1;

package nanoExpect;
use strict;
use warnings;
use IPC::Open2;
use IO::Select;

sub new {
    my $proto = shift;
    my $class = ref($proto)||$proto;

    my $self = { @_ };
    bless $self, $class;
    my ($outFh, $inFh) = (IO::Handle->new(), IO::Handle->new());
    my $pid = open2($outFh,$inFh,@{$self->{cmd}});
    $outFh->blocking(0);
    my $select = IO::Select->new($outFh);

    $self->{outFh}    = $outFh;
    $self->{inFh}     = $inFh;
    $self->{select} = $select;

    $self->cmd; #initialize
    return $self;
}

sub _printRead {
    my $self = shift;
    my $cmd = shift;
    my $inFh = $self->{inFh};
    $inFh->print($cmd."\n") if $cmd;
    $inFh->flush();
    my $buffer = '';
    my $prompt = $self->{prompt};
    while (1){
        $self->{select}->can_read();
        my $chunk;
        sysread($self->{outFh},$chunk,1024);
        $buffer .= $chunk;
        if ($buffer =~ s/${prompt}.*?> $//){
            last;
        };
    }
    warn "ANSWER: '$buffer'\n" if $self->{debug};
    return $buffer;
}

sub cmd {
    my $self = shift;
    my $cmd = shift;
    warn "  - $cmd\n" if $self->{verbose} and $cmd;
    $self->_printRead($cmd);
}

sub act {
    my $self = shift;
    my $cmd = shift;
    warn "  > $cmd\n" if $self->{verbose} and $cmd;
    $self->_printRead($cmd) unless $self->{noaction};
}


sub DESTROY {
    my $self = shift;
    my $inFh = $self->{inFh};
    print $inFh "quit\n";
    close $self->{inFh};
    close $self->{outFh};
    system "stty sane";
}

1;

package zmMailBox;
use strict;
use warnings;
use base 'nanoExpect';

sub new {
    my $class = shift;
    my $opt = { @_ };
    return $class->SUPER::new(cmd=>['zmmailbox','-z'],prompt=>'mbox',verbose=>$opt->{verbose},noaction=>$opt->{noaction},debug=>$opt->{debug});
}

1;

package zmProv;
use strict;
use warnings;
use base 'nanoExpect';

sub new {
    my $class = shift;
    my $opt = { @_ };
    return $class->SUPER::new(cmd=>['zmprov','-l'],prompt=>'prov',verbose=>$opt->{verbose},noaction=>$opt->{noaction},debug => $opt->{debug});
}

1;

