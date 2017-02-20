package ZmMailSummary::Command::provide;
use Mojo::Base 'Mojolicious::Command';

use Getopt::Long 2.25 qw(:config posix_default no_ignore_case);
use IO::Handle;
use Carp;
use Mojo::JSON qw(decode_json);
use Data::Processor;

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

    # parse options
    GetOptions(\%opt, 'help|h', 'man', 'noaction|no-action|n','all','debug', 'verbose|v')
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

    # get accounts
    my @accounts = grep /\@/, split /\n/, zmProv->new(noaction=>$opt{noaction},verbose=>$opt{verbose},debug=>$opt{debug})->cmd('gaa') ;

    my $box = zmMailBox->new(verbose=>$opt{verbose},noaction=>$opt{noaction},debug=>$opt{debug});

    for my $account (@accounts){
        # change to account
        $box->cmd("sm $account");

        next unless $account =~ /matthias/;

        # TODO exclude list

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
        my $earlier = time - $settings->{report_back_h}*3600;
        $earlier = $earlier*1000; # they want millisecs

        my @lines = split /\n/, $box->cmd("search --types message 'in:/$settings->{folder} after:$earlier'");
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
            $line =~ /^\s*\d+\.\s+\d+\s+mess\s+(.*)$/ && do {
                my $rest = $1;

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

                push @msgs, {
                    from    => $from,
                    subject => $subject,
                    date    => "$day.$month.$year $hour:$min"
                };
            };

        }

        if (scalar(@msgs) > 0){
            # load template
            open my $th, '<', 'etc/mail_template.html';
            my $subject = "new spam";
            my $msg_body = "";
            while (my $l = <$th>){
                $l =~ /^\s*subject:\s*(.*)$/ && do {
                    $subject = $1;
                    next;
                };
                $msg_body .= $l;
            }
            close $th;

            # substitute tags
            $msg_body =~ s/\{\{\s*user\s*\}\}/$account/gm;
            $msg_body =~ s/\{\{\s*report\_back\_h\s*\}\}/$settings->{report_back_h}/gm;
            my $mails_number = scalar(@msgs);
            $msg_body =~ s/\{\{\s*mails\_number\s*\}\}/$mails_number/gm;

            # send mail
            open my $mh, "|/usr/sbin/sendmail -t";
            say $mh "To: $account";
            say $account;
            my $table_rows = "";
            for (@msgs){
                $table_rows .=  "<tr><td>$_->{date}</td><td>$_->{from}</td><td>$_->{subject}</td></tr>";
            }

            $msg_body =~ s/---tablerows---/$table_rows/gm;

            say $mh $msg_body;
            close $mh;
        }
        else {
            say "$account: no mails in $settings->{folder} in the last $settings->{report_back_h} h";
        }

    }

    $say->(scalar(@accounts));

sub _read_settings{
    open my $sh, '<', 'etc/settings' or die $!; # TODO run from everywhere
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
                report_back_h => {
                    description => 'how many hours back you want reported'
                }
            }
        }
    };
    my $errors = Data::Processor->new($schema)->validate($settings);
    if ($errors->count > 0){
        say join "\n", $errors->as_array();
        exit;
    }
#~     use Data::Dumper; say Dumper $settings->{GENERAL};
#~     exit;
    return $settings->{GENERAL};
}


#~     GetOptions(\%opt, 'noaction|no-action|n', 'verbose|v');
#~     if ($opt{verbose}){
#~         $self->log->level('debug');
#~         $self->app->log->handle(\*STDOUT);
#~     }
#~
#~     say "it works";
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

