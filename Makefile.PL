use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
	'NAME'		=> 'POE::Component::SimpleDBI',
	'VERSION_FROM'	=> 'lib/POE/Component/SimpleDBI.pm', # finds $VERSION
	'PREREQ_PM'	=> {
		'POE'		=>	'0.20',
		'DBI'		=>	'1.30',
		'Error'		=>	'0.15',
		'Carp'		=>	'0',
		'Test::More'	=>	'0',
		'Test::Pod'	=>	'0',
	},
	(	$] >= 5.005 ?		# Add new keywords
		(
			'ABSTRACT_FROM'	=> 'lib/POE/Component/SimpleDBI.pm', # retrieve abstract from module
			'AUTHOR'	=> 'Apocalypse <APOCAL@cpan.org>',
			'LICENSE'	=> 'perl',
		) : ()
	),
);
