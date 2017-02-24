use 5.10.1;
use lib ('../thirdparty/lib/perl5/');
use Mojo;
use Mojo::JSON ('decode_json');
use Mojo::File;

my $path = 'zmmailsummary.cfg.dist';
my $json = Mojo::File->new($path)->slurp;
my $cfg_hash = decode_json($json);

use Data::Dumper; say Dumper $cfg_hash;
