package ZmMailSummary;

# this is the class that gets invoked in the user facing script.

use Mojo::Base 'Mojolicious';
# the command "provide" that gets run on zmMailSummary provide
use ZmMailSummary::Command::provide;

my $VERSION = "0.0.1";

=head1 NAME

ZmMailSummary - provide a summary of new mails in a Zimbra mail folder

=head1 SYNOPSIS

    bin/zmMailSummary provide

=cut

# the method that gets invoked by "start_app" in the user facing script
sub startup {
    my $app = shift;

    # register the Command folder for Mojo to find commands, there
    @{$app->commands->namespaces} = (__PACKAGE__.'::Command');
}

