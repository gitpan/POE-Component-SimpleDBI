
use strict;
use warnings;

use Module::Build 0.3601;


my %module_build_args = (
  'build_requires' => {
    'File::Find' => '0',
    'File::Temp' => '0',
    'Module::Build' => '0.3601',
    'Test::More' => '0.88'
  },
  'configure_requires' => {
    'Module::Build' => '0.3601'
  },
  'dist_abstract' => 'Asynchronous non-blocking DBI calls in POE made simple',
  'dist_author' => [
    'Apocalypse <APOCAL@cpan.org>'
  ],
  'dist_name' => 'POE-Component-SimpleDBI',
  'dist_version' => '1.30',
  'license' => 'perl',
  'module_name' => 'POE::Component::SimpleDBI',
  'recommends' => {},
  'recursive_test_files' => 1,
  'requires' => {
    'DBI' => '1.30',
    'Data::Dumper' => '0',
    'Error' => '0.15',
    'POE' => '0',
    'POE::Filter::Line' => '0',
    'POE::Filter::Reference' => '0',
    'POE::Session' => '0',
    'POE::Wheel::Run' => '0',
    'perl' => '5.006'
  },
  'script_files' => []
);


my $build = Module::Build->new(%module_build_args);

$build->create_build_script;
