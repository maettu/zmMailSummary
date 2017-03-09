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
use DBI;
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

my $say = sub {
    my $msg = shift;
    say timestamp()." $msg";
};
my $verbose = sub{
    my $msg = shift;
    $say->(" ***verbose: $msg") if $opt{verbose} or $opt{debug};
};

my $debug = sub{
    my $msg = shift;
    $say->(" ***debug: $msg") if $opt{debug};
};

sub timestamp{
    my $d = localtime;
    return sprintf ('%02d.%02d.%04d %02d:%02d:%02d', $d->mday, $d->mon, $d->year, $d->hour, $d->min, $d->sec)
}


sub run {
    my $self = shift;
    local @ARGV = @_;
    GetOptions(\%opt, 'noaction|no-action|n', 'debug|d', 'verbose|v', 'account-names=s', 'force|f')
        or exit(1);
    if ($opt{noaction}) {
        $opt{verbose} = 1 ;
        warn timestamp()." *** NO ACTION MODE ***\n";
    }

    croak "$0 only works when running as user 'zimbra'"
        unless ($ENV{USER} eq 'zimbra');

    # read settings
    my $settings = _read_settings();
    my @excludes = _read_file_with_mail_addresses($settings->{exclude_file});
    my @only_send_to = ();
    $settings->{only_send_to} and do {
        @only_send_to = _read_file_with_mail_addresses($settings->{only_send_to});
        $debug->("only sending to:");
        $debug->("----------------");
        $debug->(join "\n", @only_send_to);
        $debug->("----------------");
    };

    # open database with timestamps when we last sent to a user
    my $db_file = "$FindBin::RealBin/../var/send_timestamps";
    my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", "", "");
    $dbh->{AutoCommit} = 1;
    my $sth = $dbh->prepare('create table if not exists last_sent (mail TEXT, timestamp INTEGER, primary key (mail))');
    $sth->execute;

    # get accounts
    my $zmProv = zmProv->new(
        noaction=>$opt{noaction},
        verbose=>$opt{verbose},
        debug=>$opt{debug}
    );
    my @accounts = grep /\@/, split /\n/, $zmProv->cmd('gaa');
    $say->(scalar(@accounts). ' accounts');

    my $box = zmMailBox->new(verbose=>$opt{verbose},noaction=>$opt{noaction},debug=>$opt{debug});

    my $c = 0;
    for my $account (@accounts){
        $c++;
        $say->("$c/".scalar(@accounts)." $account");
        $opt{'account-names'} && do {
            $account =~ /$opt{'account-names'}/ || do {
                $say->("skip $account, does not match $opt{'account-names'}");
                next;
            }
        };

        $settings->{only_send_to} && do {
            unless (_in_list($account, @only_send_to)){
                $say->("skip $account, not in only_send_to list");
                next;
            }
        };

        if (_in_list($account, @excludes)){
            $say->("skip account, found in exlude list");
            next;
        }

        # the MailboxManager tool sets amavisBlacklistSender: $settings->{unsubscribe}
        my @blacklist = grep /amavisBlacklistSender:.*$settings->{unsubscribe}/, split /\n/, $zmProv->cmd("ga $account");
        @blacklist && do {
            $say->("skip $account, has option set in Mailmanager");
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
            $say->("*** $account: no folder $settings->{folder}");
            next;
        }

        # read all messages
        # report -x days until yesterday
        my $t = localtime;
        my $end_report = timelocal(0,0,0, $t->mday, $t->mon-1, $t->year)*1000; # millisecs for zmmailbox
        $t -= ONE_DAY for (1..$settings->{report_back_days});
        my $start_report = timelocal(0,0,0, $t->mday, $t->mon-1, $t->year)*1000-1;
        # fetch the first messages
        my $r = $box->cmd("search -v --types message 'in:/$settings->{folder} after:$start_report before:$end_report'");
        # delete first line, which is the command
        $r =~ s/.*?\n//m;
        $r = decode_json($r);
        my @msgs; # array of hashes [{from => foo@bar.com, date => 01/25/17, msg => whatever, I mailed it}]
        while (1){
            for my $m (@{$r->{hits}}){
                my $d = localtime($m->{date}/1000);
                my $date_string = sprintf ('%02d.%02d.%04d %02d:%02d', $d->mday, $d->mon, $d->year, $d->hour, $d->min);

                push @msgs, {
                    url     => "$settings->{zimbra_url}/?id=$m->{id}",
                    from    => $m->{sender}{address},
                    from_full => $m->{sender}{fullAddressQuoted},
                    from_display => $m->{sender}{display},
                    from_personal => $m->{sender}{personal},
                    subject => $m->{subject},
                    date    => $date_string,
                };
            }


            my $more = $r->{more};
            last unless $more == 1;
            $r = $box->cmd('search -v --next');
            $r =~ s/.*?\n//m;
            $r = decode_json $r;
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

            $say->("send account: '$account' to: '$send_to'");

            $opt{noaction} && do {
                $say->("noaction: skip sending");
                next;
            };

            # if the largest value found is older than midnight,
            # send mail, and, on success,
            # delete all, add current time
            $sth = $dbh->prepare("select count(mail) from last_sent where mail = '$account'");
            $sth->execute;
            my $sent_earlier = $sth->fetch->[0];

            if ($sent_earlier){
                $sth = $dbh->prepare("select timestamp from last_sent where mail = '$account'");
                $sth->execute;
                my $timestamp = $sth->fetch->[0];
                $timestamp > $end_report && do {
                    $say->("$timestamp > $end_report ");
                    if ($opt{force}){
                        $say->("force overrule skip");
                    }
                    else {
                        $say->("already sent today: skip");
                        next;
                    }
                }
            }
            else {
                $debug->("no timestamp of former send action found");
            }

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

                # could not get Email::MIME to produce a content-id that is picked up
                # by my mail clients. Workarounding this in "disposition"
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

                my $time = time * 1000;
                my $stmt;
                $sent_earlier
                    ? ($stmt = "update last_sent set timestamp=$time where mail = '$account'")
                    : ($stmt = "insert into last_sent values ('$account', $time)");

                $debug->("sent_earlier: $sent_earlier, stmt: $stmt");
                $sth = $dbh->prepare($stmt);
                $sth->execute;

                $debug->($email->as_string);
            };
            $@ && do {
                warn "sending failed $@";
            }

        }
        else {
            $say->("skip $account: no mails in $settings->{folder} in the last $settings->{report_back_days} days");
        }
    }
}

sub _get_user_locale{
    my $zmProv = shift;
    my $account = shift;
    my $settings = shift;
    my @user_locale_lines = grep /zimbraPrefLocale/i, split /\n/, $zmProv->cmd("ga $account");
    $debug->("-- $account --");
    my $user_locale = $settings->{default_language};
    $user_locale_lines[0] && do {
        $user_locale_lines[0] =~ /: (.*)$/;
        # default to default_language if not set or not in our list of available languages
        $user_locale = $1 // $settings->{default_language};
        $user_locale = $settings->{default_language}
            unless _in_list($user_locale, @{$settings->{available_languages}});
    };
    $debug->("locale: $user_locale");
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
                only_send_to => {
                    optional => 1,
                    description => 'If this option is set, only mail addresses in this file get a mail.',
                    validator => sub {
                        my $file = shift;
                        return undef if -f "$FindBin::RealBin/../$file";
                        return "file $file does not exist";
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

sub _read_file_with_mail_addresses{
    my $file = shift;
    open my $xh, '<', "$FindBin::RealBin/../$file" or die $!;
    my @mails;
    while (<$xh>){
        chomp;
        s/^\s*//;
        s/\s*$//;
        next if /^\s*$/;
        push @mails, $_;
    }
    return @mails;
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

