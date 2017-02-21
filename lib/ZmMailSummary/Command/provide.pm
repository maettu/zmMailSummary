package ZmMailSummary::Command::provide;
use Mojo::Base 'Mojolicious::Command';

use Getopt::Long 2.25 qw(:config posix_default no_ignore_case);
use IO::Handle;
use Carp;
use FindBin;
use Mojo::JSON qw(decode_json);
use Mojo::File;
use Data::Processor;
use Encode;
use Time::Piece;
use Time::Seconds;
binmode (STDOUT, ':utf8');

=head1 NAME

ZmMailSummary::Command::provide - provide a summary of new mail in a folder by sending mail to each user.

=head1 SYNOPSIS

    zmMailSummary provide

    options:
        -n | --noaction don't send mails.
        -v | --verbose  be very noisy
        --account-names a regex; send only to names matching


=head1 DESCRIPTION

whatever

=cut

has description => 'this is what gets printed on "perl bin/test.pl help"';
# extract the usage information from the SYNOPSIS
# e.g. "perl bin/test.pl help go"
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


# gets called by Mojo
sub run {
    my $self = shift;
    local @ARGV = @_;
    # parse options
    GetOptions(\%opt, 'help|h', 'man', 'noaction|no-action|n','all','debug|d', 'verbose|v', 'account-names=s')
        or exit(1);
    if ($opt{help})     { pod2usage(1) }
    if ($opt{man})      { pod2usage(-exitstatus => 0, -verbose => 2, -noperldoc=>1) }
    if ($opt{noaction}) {
        $opt{verbose} = 1 ;
        warn "*** NO ACTION MODE ***\n";
    }

    if ($ENV{USER} ne 'zimbra'){
        croak "$0 only works when running as user 'zimbra'";
    }

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
        # change to account
        $box->cmd("sm $account");

        $opt{'account-names'} && do {
            $account =~ /$opt{'account-names'}/ || do {
                $debug->("skip $account, does not match $opt{'account-names'}");
                next;
            }
        };

        next if _in_list($account, @excludes);

        $say->("account: $account");


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
        # needs " to quote folder, ' do not work
        # fetch the first messages
        my $t = localtime;
        my $today = sprintf("%02d/%02d/%04d", $t->mon,$t->mday,$t->year);
        $t -= ONE_DAY for (1..$settings->{report_back_days}+1);
        my $one_day_before_start = sprintf("%02d/%02d/%04d", $t->mon,$t->mday,$t->year);
        # report -x days until yesterday
        my @lines = split /\n/, $box->cmd("search --types message 'in:/$settings->{folder} after:$one_day_before_start before:$today'");
        my @field_positions;
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
                    from    => $from,
                    subject => $subject,
                    date    => "$day.$month.$year $hour:$min"
                };
            };

        }

        if (scalar(@msgs) > 0){
            # load template
            # user language
            my $user_locale = _get_user_locale($zmProv, $account, $settings);

            # this should never fail because we check file existence during config validation
            my $path = Mojo::File->new(
                "$FindBin::RealBin/../templates/mail_template_$user_locale.txt.ep"
            );
            my $r = {
                user => $account,
                report_back_days => $settings->{report_back_days},
                mails_number => scalar(@msgs),
                msgs => \@msgs,
            };

            my $template = '% my $r = shift;'."\n";
            $template.= decode('UTF-8', $path->slurp);

            say "sending to $account";

            $opt{noaction} && do {
                say "noaction: skip sending";
                next;
            };

            # send mail
            open my $mh, "|/usr/sbin/sendmail -t";
            say $mh "To: $account";
            say $mh encode('UTF-8', Mojo::Template->new->render($template, $r));
            close $mh;
        }
        else {
            say "$account: no mails in $settings->{folder} in the last $settings->{report_back_days} days";
        }

    }

    $say->(scalar(@accounts));
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
                        return undef if -f $value;
                        return "file $value does not exist";
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
                        my $value = shift;
                        return "please supply an array" unless ref $value eq "ARRAY";
                        my @errors;
                        for (@{$value}){
                            push @errors, "templates/mail_template_$_.txt.ep not found"
                                unless -f "templates/mail_template_$_.txt.ep";
                        }
                        return "\n". join "\n", @errors if @errors;
                        return 0;
                    }
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

