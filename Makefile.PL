
use strict;
use warnings;

BEGIN { require 5.006; }

use ExtUtils::MakeMaker 6.31;



my %WriteMakefileArgs = (
  'ABSTRACT' => 'Asynchronous non-blocking DBI calls in POE made simple',
  'AUTHOR' => 'Apocalypse <APOCAL@cpan.org>',
  'BUILD_REQUIRES' => {
    'File::Find' => '0',
    'File::Temp' => '0',
    'ExtUtils::MakeMaker' => '6.31',
    'Test::More' => '0.88'
  },
  'CONFIGURE_REQUIRES' => {
    'ExtUtils::MakeMaker' => '6.31'
  },
  'DISTNAME' => 'POE-Component-SimpleDBI',
  'EXE_FILES' => [],
  'LICENSE' => 'perl',
  'NAME' => 'POE::Component::SimpleDBI',
  'PREREQ_PM' => {
    'DBI' => '1.30',
    'Data::Dumper' => '0',
    'Error' => '0.15',
    'POE' => '0',
    'POE::Filter::Line' => '0',
    'POE::Filter::Reference' => '0',
    'POE::Session' => '0',
    'POE::Wheel::Run' => '0'
  },
  'VERSION' => '1.30',
  'test' => {
    'TESTS' => 't/*.t'
  }
);


unless ( eval { ExtUtils::MakeMaker->VERSION(6.56) } ) {
  my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
  my $pp = $WriteMakefileArgs{PREREQ_PM};
  for my $mod ( keys %$br ) {
    if ( exists $pp->{$mod} ) {
      $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
    }
    else {
      $pp->{$mod} = $br->{$mod};
    }
  }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);



