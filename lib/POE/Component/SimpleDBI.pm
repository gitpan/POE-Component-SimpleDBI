# Declare our package
package POE::Component::SimpleDBI;

# Standard stuff to catch errors
use strict qw(subs vars refs);				# Make sure we can't mess up
use warnings FATAL => 'all';				# Enable warnings to catch errors

# Initialize our version
our $VERSION = do { my @r = (q$Revision: 1.2 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };

# Import what we need from the POE namespace
use POE;			# For the constants
use POE::Session;		# To create our own :)
use POE::Filter::Reference;	# For communicating with the subprocess
use POE::Filter::Line;		# For subprocess STDERR messages
use POE::Wheel::Run;		# For the nitty-gritty details of 'fork'

# Use the SubProcess for our child process
use POE::Component::SimpleDBI::SubProcess;

# Other miscellaneous modules we need
use Carp;

# Our own definition of the max retries
sub MAX_RETRIES () { 5 }
sub DEBUG () { 0 }

# Set things in motion!
sub new {
	# Get the OOP's type
	my $type = shift;

	# Sanity checking
	if ( @_ & 1 ) {
		croak( 'POE::Component::SimpleDBI->new needs even number of options' );
	}

	# The options hash
	my %opt = @_;

	# Our own options
	my ( $DSN, $ALIAS, $USERNAME, $PASSWORD );

	# You could say I should do this: $Stuff = delete $opt{'Stuff'}
	# But, that kind of behavior is not defined, so I would not trust it...

	# Get the DSN
	if ( exists $opt{'DSN'} ) {
		$DSN = $opt{'DSN'};
		delete $opt{'DSN'};
	} else {
		croak( 'DSN is required to create a new POE::Component::SimpleDBI instance!' );
	}

	# Get the USERNAME
	if ( exists $opt{'USERNAME'} ) {
		$USERNAME = $opt{'USERNAME'};
		delete $opt{'USERNAME'};
	} else {
		croak( 'USERNAME is required to create a new POE::Component::SimpleDBI instance!' );
	}

	# Get the PASSWORD
	if ( exists $opt{'PASSWORD'} ) {
		$PASSWORD = $opt{'PASSWORD'};
		delete $opt{'PASSWORD'};
	} else {
		croak( 'PASSWORD is required to create a new POE::Component::SimpleDBI instance!' );
	}

	# Get the session alias
	if ( exists $opt{'ALIAS'} ) {
		$ALIAS = $opt{'ALIAS'};
		delete $opt{'ALIAS'};
	} else {
		# Debugging info...
		if ( DEBUG ) {
			warn 'Using default ALIAS = SimpleDBI';
		}

		# Set the default
		$ALIAS = 'SimpleDBI';
	}

	# Anything left over is unrecognized
	if ( keys %opt > 0 ) {
		croak( 'Unrecognized options were present in POE::Component::SimpleDBI->new!' );
	}

	# Create a new session for ourself
	POE::Session->create(
		# Our subroutines
		'inline_states'	=>	{
			# Maintenance events
			'_start'	=>	\&Start,
			'_stop'		=>	\&Stop,
			'Setup_Wheel'	=>	\&Setup_Wheel,

			# Shutdown stuff
			'shutdown'	=>	\&Clean_Shutdown,
			'shutdown_NOW'	=>	\&Real_Shutdown,

			# IO events
			'ChildError'	=>	\&ChildError,
			'ChildClosed'	=>	\&ChildClosed,
			'Got_STDOUT'	=>	\&Got_STDOUT,
			'Got_STDERR'	=>	\&Got_STDERR,
			'SendWheel'	=>	\&SendWheel,

			# DB events
			'DO'		=>	\&DB_HANDLE,
			'SINGLE'	=>	\&DB_HANDLE,
			'MULTIPLE'	=>	\&DB_HANDLE,
			'QUOTE'		=>	\&DB_HANDLE,

			# Queue stuff
			'Send_Query'	=>	\&Send_Query,
			'Check_Queue'	=>	\&Check_Queue,
		},

		# Set up the heap for ourself
		'heap'		=>	{
			# The queue of DBI calls
			'QUEUE'		=>	[],
			'IDCounter'	=>	0,

			# The Wheel::Run object
			'WHEEL'		=>	undef,

			# How many times have we re-created the wheel?
			'Retries'	=>	0,

			# Are we shutting down?
			'SHUTDOWN'	=>	0,

			# The DB Info
			'DSN'		=>	$DSN,
			'USERNAME'	=>	$USERNAME,
			'PASSWORD'	=>	$PASSWORD,

			# The alias we will run under
			'ALIAS'		=>	$ALIAS,
		},
	) or die 'Unable to create a new session!';

	# Return success
	return 1;
}

# This subroutine handles SHUTDOWN signals
sub Clean_Shutdown {
	# Do not accept any more queries
	$_[HEAP]->{'SHUTDOWN'} = 1;

	# Put into the queue EXIT for the child
	$_[KERNEL]->yield( 'Send_Query', {
		'ACTION'	=>	'EXIT',
		'SQL'		=>	undef,
		'PLACEHOLDERS'	=>	undef,
		}
	);

	# Remove our alias so we can be properly terminated
	$_[KERNEL]->alias_remove( $_[HEAP]->{'ALIAS'} );
}

# This subroutine kills our subprocess
sub Real_Shutdown {
	# Do not accept any more queries
	$_[HEAP]->{'SHUTDOWN'} = 2;

	# Remove our alias so we can be properly terminated
	$_[KERNEL]->alias_remove( $_[HEAP]->{'ALIAS'} );

	# KILL our subprocess
	$_[HEAP]->{'WHEEL'}->kill( -9 );

	# Delete the wheel, so we have nothing to keep the GC from destructing us...
	delete $_[HEAP]->{'WHEEL'};

	# Post a failure event to all the queries on the Queue, informing them that we have been shutdown...
	foreach my $queue ( @{ $_[HEAP]->{'QUEUE'} } ) {
		$_[KERNEL]->post( $queue->{'SESSION'}, $queue->{'EVENT_E'}, {
			'SQL'		=>	$queue->{'SQL'},
			'PLACEHOLDERS'	=>	$queue->{'PLACEHOLDERS'},
			'ERROR'		=>	'POE::Component::SimpleDBI was shut down forcibly!',
			},
		);
	}

	# Tell the kernel to kill us!
	$_[KERNEL]->signal( $_[SESSION], 'KILL' );
}

# This subroutine handles MULTIPLE + SINGLE + DO queries
sub DB_HANDLE {
	# Get the arguments
	my %args = @_[ARG0 .. $#_ ];

	# Add some stuff to the args
	$args{'SESSION'} = $_[SENDER]->ID();
	$args{'ACTION'} = $_[STATE];

	# Check for the Failure Event
	if ( ! exists $args{'EVENT_E'} ) {
		# Nothing much we can do except drop this quietly...
		warn "Did not receive an EVENT_E argument from caller " . $_[SESSION]->ID . " -> State: " . $_[STATE] . " Args: " . %args;
		return;
	} else {
		if ( ref( $args{'EVENT_E'} ne 'SCALAR' ) ) {
			# Same quietness...
			warn "Received an malformed EVENT_E argument from caller " . $_[SESSION]->ID . " -> State: " . $_[STATE] . " Args: " . %args;
			return;
		}
	}

	# Check for the Success Event
	if ( ! exists $args{'EVENT_S'} ) {
		# Okay, send the error to the Failure Event
		$_[KERNEL]->post( $args{'SESSION'}, $args{'EVENT_E'}, {
			'SQL'		=>	undef,
			'PLACEHOLDERS'	=>	undef,
			'ERROR'		=>	'EVENT_S is not defined!',
			}
		);
		return;
	} else {
		if ( ref( $args{'EVENT_S'} ) ) {
			# Okay, send the error to the Failure Event
			$_[KERNEL]->post( $args{'SESSION'}, $args{'EVENT_E'}, {
				'SQL'		=>	undef,
				'PLACEHOLDERS'	=>	undef,
				'ERROR'		=>	'EVENT_S is not a scalar!',
				}
			);
			return;
		}
	}

	# Check for SQL
	if ( ! exists $args{'SQL'} ) {
		# Okay, send the error to the Failure Event
		$_[KERNEL]->post( $args{'SESSION'}, $args{'EVENT_E'}, {
			'SQL'		=>	undef,
			'PLACEHOLDERS'	=>	undef,
			'ERROR'		=>	'SQL is not defined!',
			}
		);
		return;
	} else {
		if ( ref( $args{'SQL'} ) ) {
			# Okay, send the error to the Failure Event
			$_[KERNEL]->post( $args{'SESSION'}, $args{'EVENT_E'}, {
				'SQL'		=>	undef,
				'PLACEHOLDERS'	=>	undef,
				'ERROR'		=>	'SQL is not a scalar!',
				}
			);
			return;
		}
	}

	# Check for placeholders
	if ( ! exists $args{'PLACEHOLDERS'} ) {
		# Create our own empty placeholders
		$args{'PLACEHOLDERS'} = [];
	} else {
		if ( ref( $args{'PLACEHOLDERS'} ) ne 'ARRAY' ) {
			# Okay, send the error to the Failure Event
			$_[KERNEL]->post( $args{'SESSION'}, $args{'EVENT_E'}, {
				'SQL'		=>	$args{'SQL'},
				'PLACEHOLDERS'	=>	undef,
				'ERROR'		=>	'PLACEHOLDERS is not an array!',
				}
			);
			return;
		}
	}

	# Check if we have shutdown or not
	if ( $_[HEAP]->{'SHUTDOWN'} ) {
		# Do not accept this query
		$_[KERNEL]->post( $args{'SESSION'}, $args{'EVENT_E'}, {
			'SQL'		=>	$args{'SQL'},
			'PLACEHOLDERS'	=>	$args{'PLACEHOLDERS'},
			'ERROR'		=>	'POE::Component::SimpleDBI is shutting down now, requests are not accepted!',
			}
		);
		return;
	}

	# Okay, fire off this query!
	$_[KERNEL]->yield( 'Send_Query', \%args );
}

# This subroutine starts the process of sending a query
sub Send_Query {
	# Validate that we have something
	if ( ! defined $_[ARG0] ) {
		return;
	} else {
		# Must be hash
		if ( ref( $_[ARG0] ) ne 'HASH' ) {
			return;
		}
	}

	# Add the ID to the query
	$_[ARG0]->{'ID'} = $_[HEAP]->{'IDCounter'}++;

	# Add this query to the queue
	push( @{ $_[HEAP]->{'QUEUE'} }, $_[ARG0] );

	# Send the query!
	$_[KERNEL]->call( $_[SESSION], 'Check_Queue' );
}

# This subroutine does the meat - sends queries to the subprocess
sub Check_Queue {
	# Check if the subprocess is currently active
	if ( ! $_[HEAP]->{'ACTIVE'} ) {
		# Check if we have a query in the queue
		if ( scalar( @{ $_[HEAP]->{'QUEUE'} } ) > 0 ) {
			# Copy what we need from the top of the queue
			my %queue;
			$queue{'ID'} = @{ $_[HEAP]->{'QUEUE'} }[0]->{'ID'};
			$queue{'SQL'} = @{ $_[HEAP]->{'QUEUE'} }[0]->{'SQL'};
			$queue{'ACTION'} = @{ $_[HEAP]->{'QUEUE'} }[0]->{'ACTION'};
			$queue{'PLACEHOLDERS'} = @{ $_[HEAP]->{'QUEUE'} }[0]->{'PLACEHOLDERS'};

			# Fire off something!
			$_[KERNEL]->call( $_[SESSION], 'SendWheel', \%queue );
		}
	}
}

# This starts the SimpleDBI
sub Start {
	# Set up the alias for ourself
	$_[KERNEL]->alias_set( $_[HEAP]->{'ALIAS'} );

	# Create the wheel
	$_[KERNEL]->yield( 'Setup_Wheel' );
}

# This sets up the WHEEL
sub Setup_Wheel {
	# Are we shutting down?
	if ( $_[HEAP]->{'SHUTDOWN'} ) {
		# Do not re-create the wheel...
		return;
	}

	# Check if we should set up the wheel
	if ( $_[HEAP]->{'Retries'} >= MAX_RETRIES ) {
		die 'POE::Component::SimpleDBI tried ' . MAX_RETRIES . ' times to create a Wheel and is giving up...';
	}

	# Set up the SubProcess we communicate with
	$_[HEAP]->{'WHEEL'} = POE::Wheel::Run->new(
		# What we will run in the separate process
		'Program'	=>	\&POE::Component::SimpleDBI::SubProcess::main,
		'ProgramArgs'	=>	[ $_[HEAP]->{'DSN'}, $_[HEAP]->{'USERNAME'}, $_[HEAP]->{'PASSWORD'} ],

		# Kill off existing FD's
		'CloseOnCall'	=>	1,

		# Redirect errors to our error routine
		'ErrorEvent'	=>	'ChildError',

		# Send child died to our child routine
		'CloseEvent'	=>	'ChildClosed',

		# Send input from child
		'StdoutEvent'	=>	'Got_STDOUT',

		# Send input from child STDERR
		'StderrEvent'	=>	'Got_STDERR',

		# Set our filters
		'StdinFilter'	=>	POE::Filter::Reference->new(),		# Communicate with child via Storable::nfreeze
		'StdoutFilter'	=>	POE::Filter::Reference->new(),		# Receive input via Storable::nfreeze
		'StderrFilter'	=>	POE::Filter::Line->new(),		# Plain ol' error lines
	);

	# Check for errors
	if ( ! defined $_[HEAP]->{'WHEEL'} ) {
		die 'Unable to create a new wheel!';
	} else {
		# Increment our retry count
		$_[HEAP]->{'Retries'}++;

		# Set the wheel to inactive
		$_[HEAP]->{'ACTIVE'} = 0;

		# Check for queries
		$_[KERNEL]->call( $_[SESSION], 'Check_Queue' );
	}
}

# Stops everything we have
sub Stop {
	# Hmpf, what should I put in here?
}

# Handles sending all output to the child process
sub SendWheel {
	# Send data only if we are not shutting down...
	if ( $_[HEAP]->{'SHUTDOWN'} != 2 ) {
		# Set the child to 'active'
		$_[HEAP]->{'ACTIVE'} = 1;

		# Put it in the wheel
		$_[HEAP]->{'WHEEL'}->put( $_[ARG0] );
	}
}

# Handles child DIE'ing
sub ChildClosed {
	# Emit debugging information
	if ( DEBUG ) {
		warn 'POE::Component::SimpleDBI\'s Wheel died! Restarting it...';
	}

	# Create the wheel again
	delete $_[HEAP]->{'WHEEL'};
	$_[KERNEL]->call( $_[SESSION], 'Setup_Wheel' );
}

# Handles child error
sub ChildError {
	# Emit warnings only if debug is on
	if ( DEBUG ) {
		# Copied from POE::Wheel::Run manpage
		my ( $operation, $errnum, $errstr, $wheel_id ) = @_[ARG0..ARG3];
		warn "POE::Component::SimpleDBI got an $operation error $errnum: $errstr\n";
	}
}

# Handles child STDOUT output
sub Got_STDOUT {
	# Validate the argument
	if ( ref( $_[ARG0] ) ne 'HASH' ) {
		warn 'POE::Component::SimpleDBI Did not get a hash from the child';
		return;
	}

	# Check to see if the ID matches with the top of the queue
	if ( $_[ARG0]->{'ID'} ne @{ $_[HEAP]->{'QUEUE'} }[0]->{'ID'} ) {
		die 'Internal error in queue/child consistency!';
	}

	# Get the query from the top of the queue
	my $query = shift( @{ $_[HEAP]->{'QUEUE'} } );

	# See if this is an error
	if ( exists $_[ARG0]->{'ERROR'} ) {
		# Send this to the Error handler
		$_[KERNEL]->post( $query->{'SESSION'}, $query->{'EVENT_E'}, {
			'SQL'		=>	$query->{'SQL'},
			'PLACEHOLDERS'	=>	$query->{'PLACEHOLDERS'},
			'ERROR'		=>	$_[ARG0]->{'ERROR'},
			}
		);
	} else {
		# Send the data to the appropriate place
		$_[KERNEL]->post( $query->{'SESSION'}, $query->{'EVENT_S'}, {
			'SQL'		=>	$query->{'SQL'},
			'PLACEHOLDERS'	=>	$query->{'PLACEHOLDERS'},
			'RESULTS'	=>	$_[ARG0]->{'DATA'},
			'ACTION'	=>	$query->{'ACTION'},
			}
		);
	}

	# Now, that we have got a result, check if we need to send another query
	$_[HEAP]->{'ACTIVE'} = 0;
	$_[KERNEL]->call( $_[SESSION], 'Check_Queue' );
}

# Handles child STDERR output
sub Got_STDERR {
	my $input = $_[ARG0];

	# Skip empty lines as the POE::Filter::Line manpage says...
	if ( $input eq '' ) { return }

	warn "POE::Component::SimpleDBI Got STDERR from child, which should never happen ( $input )";
}

# End of module
1;

__END__

=head1 NAME

POE::Component::SimpleDBI - Perl extension for asynchronous non-blocking DBI calls in POE

=head1 SYNOPSIS

	use POE;
	use POE::Component::SimpleDBI;

	# Set up the DBI
	POE::Component::SimpleDBI->new(
		ALIAS	=> 'SimpleDBI',
		DSN	=> 'DBI:mysql:database=foobaz;host=192.168.1.100;port=3306',
		USERNAME => 'FooBar',
		PASSWORD => 'SecretPassword',
	) or die 'Unable to create the DBI session';

	# Create our own session to communicate with SimpleDBI
	POE::Session->create(
		inline_states => {
			_start => sub {
				$_[KERNEL]->post( 'SimpleDBI', 'DO',
					SQL => 'DELETE FROM FooTable WHERE ID = ?',
					PLACEHOLDERS => [ qw( 38 ) ],
					EVENT_S => 'deleted_handler',
					EVENT_E => 'error_handler',
				);

				$_[KERNEL]->post( 'SimpleDBI', 'SINGLE',
					SQL => 'Select * from FooTable',
					EVENT_S => 'success_handler',
					EVENT_E => 'error_handler',
				);

				$_[KERNEL]->post( 'SimpleDBI', 'MULTIPLE',
					SQL => 'SELECT foo, baz FROM FooTable2 WHERE id = ?',
					EVENT_S => 'multiple_handler',
					EVENT_E => 'error_handler',
					PLACEHOLDERS => [ qw( 53 ) ],
				);

				$_[KERNEL]->post( 'SimpleDBI', 'QUOTE',
					SQL => 'foo$*@%%sdkf"""',
					EVENT_S => 'quote_handler',
					EVENT_E => 'error_handler',
				);

				# 3 ways to shutdown

				# This will let the existing queries finish, then shutdown
				$_[KERNEL]->post( 'SimpleDBI', 'shutdown' );

				# This will terminate when the event traverses
				# POE's queue and arrives at SimpleDBI
				$_[KERNEL]->post( 'SimpleDBI', 'shutdown_NOW' );

				# Even QUICKER shutdown :)
				$_[KERNEL]->call( 'SimpleDBI', 'shutdown_NOW' );
			},

			success_handler => \&success_handler,
			deleted_handler => \&deleted_handler,
			quote_handler	=> \&quote_handler,
			multiple_handler => \&multiple_handler,
			error_handler => \&error_handler,
		},
	);

	sub quote_handler {
		# For QUOTE calls, we receive the scalar string of SQL quoted
		# $_[ARG0] = {
		#	SQL => The SQL You put in
		#	RESULTS	=> scalar quoted SQL
		#	PLACEHOLDERS => The placeholders
		#	ACTION => QUOTE
		# }
	}

	sub deleted_handler {
		# For DO calls, we receive the scalar value of rows affected
		# $_[ARG0] = {
		#	SQL => The SQL You put in
		#	RESULTS	=> scalar value of rows affected
		#	PLACEHOLDERS => The placeholders
		#	ACTION => DO
		# }
	}

	sub success_handler {
		# For SINGLE calls, we receive a hash ( similar to fetchrow_hash )
		# $_[ARG0] = {
		#	SQL => The SQL You put in
		#	RESULTS	=> hash
		#	PLACEHOLDERS => The placeholders
		#	ACTION => SINGLE
		# }
	}

	sub multiple_handler {
		# For MULTIPLE calls, we receive an array of hashes
		# $_[ARG0] = {
		#	SQL => The SQL You put in
		#	RESULTS	=> array of hashes
		#	PLACEHOLDERS => The placeholders
		#	ACTION => MULTIPLE
		# }
	}

	sub error_handler {
		# Errors, we receive an scalar string
		# $_[ARG0] = {
		#	SQL => The SQL You put in
		#	ERROR => ERRORSTRING
		#	PLACEHOLDERS => The placeholders
		# }
	}

=head1 ABSTRACT

	This module simplifies DBI usage in POE's multitasking world.

	This module is a breeze to use, you'll have DBI calls in your POE program
	up and running in only a few seconds of setup.

	If you want more advanced usage, check out:
		POE::Component::LaDBI

	If you want even simpler usage, check out:
		POE::Component::DBIAgent

=head1 DESCRIPTION

This module works its magic by creating a new session with POE, then spawning off a child process
to do the "heavy" lifting. That way, your main POE process can continue servicing other clients.

The standard way to use this module is to do this:

	use POE;
	use POE::Component::SimpleDBI;

	POE::Component::SimpleDBI->new( ... );

	POE::Session->create( ... );

	POE::Kernel->run();

=head2 The only function you can call is POE::Component::SimpleDBI->new()

This constructor accepts only 4 different options.

=over 4

=item C<ALIAS>

This will set the alias SimpleDBI uses in the POE Kernel.
This will default TO "SimpleDBI"

=item C<DSN>

This is the DSN -> Database connection string

SimpleDBI expects this to contain everything you need to connect to a database
via DBI, sans the username and password.

For valid DSN strings, contact your DBI manual.

=item C<USERNAME>

Simply put, this is the DB username SimpleDBI will use.

=item C<PASSWORD>

Simply put, this is the DB password SimpleDBI will use.

=back

=head2 Semantics of SimpleDBI

SimpleDBI has a few Event states you need to know about.

=over 4

=item C<EVENT_S>

This is the success event, triggered whenever a query finished successfully.

It will get a hash in ARG0, consult the specific queries on what you will get.

=item C<EVENT_E>

This is the error event, triggered whenever a query gets an error.

It will get a plain string in ARG0, signifying the error.

=back

=head2 Event Handlers

SimpleDBI has a few events you can send to.

They all share a common argument system.

=over 4

=item C<SQL>

This is the actual SQL line you want SimpleDBI to execute.
You can put in placeholders, this module supports them.

=item C<PLACEHOLDERS>

This is an array of placeholders.

You can skip this if your query does not utilize it.

=item C<EVENT_S>

This is the success event state.

=item C<EVENT_E>

This is the error event state.

=back

=head3 Events

=over 4

=item C<QUOTE>

	This simply sends off a string to be quoted, and gets it back.

	Internally, it does this:

	return $dbh->quote( $SQL );

	Here's an example on how to trigger this event:

	$_[KERNEL]->post( 'SimpleDBI', 'QUOTE',
		SQL => 'foo$*@%%sdkf"""',
		EVENT_S => 'quote_handler',
		EVENT_E => 'error_handler',
	);

	The Success Event handler will get a hash in ARG0:
	{
		'SQL'		=>	Original SQL inputted
		'RESULTS'	=>	Quoted SQL
	}

=item C<DO>

	This query is specialized for those queries where you UPDATE/DELETE/etc.
	THIS IS NOT for SELECT QUERIES!

	Internally, it does this:

	$sth = $dbh->prepare_cached( $SQL );
	$rows_affected = $sth->execute( $PLACEHOLDERS );
	return $rows_affected;

	Here's an example on how to trigger this event:

	$_[KERNEL]->post( 'SimpleDBI', 'DO',
		SQL => 'DELETE FROM FooTable WHERE ID = ?',
		PLACEHOLDERS => [ qw( 38 ) ],
		EVENT_S => 'deleted_handler',
		EVENT_E => 'error_handler',
	);

	The Success Event handler will get a hash in ARG0:
	{
		'SQL'		=>	Original SQL inputted
		'RESULTS'	=>	Scalar value of rows affected
		'PLACEHOLDERS'	=>	Original placeholders
	}

=item C<SINGLE>

	This query is specialized for those queries where you will get exactly 1 result back.

	NOTE: This subroutine will automatically append ' LIMIT 1' to all queries passed in.
	If this behavior is not desirable, please contact me and I will update SimpleDBI.

	Internally, it does this:

	$sth = $dbh->prepare_cached( $SQL );
	$sth->bind_columns( %result );
	$sth->execute( $PLACEHOLDERS );
	$sth->fetch();
	return %result;

	Here's an example on how to trigger this event:

	$_[KERNEL]->post( 'SimpleDBI', 'SINGLE',
		SQL => 'Select * from FooTable',
		EVENT_S => 'success_handler',
		EVENT_E => 'error_handler',
	);

	The Success Event handler will get a hash in ARG0:
	{
		'SQL'		=>	Original SQL inputted
		'RESULTS'	=>	Hash of rows - similar to fetchrow_hashref
		'PLACEHOLDERS'	=>	Original placeholders
	}

=item C<MULTIPLE>

	This query is specialized for those queries where you will get more than 1 result back.

	Internally, it does this:

	$sth = $dbh->prepare_cached( $SQL );
	$sth->bind_columns( %result );
	$sth->execute( $PLACEHOLDERS );
	while ( $sth->fetch() ) {
		push( @results, %row );
	}
	return @results;

	Here's an example on how to trigger this event:

	$_[KERNEL]->post( 'SimpleDBI', 'MULTIPLE',
		SQL => 'SELECT foo, baz FROM FooTable2 WHERE id = ?',
		EVENT_S => 'multiple_handler',
		EVENT_E => 'error_handler',
		PLACEHOLDERS => [ qw( 53 ) ],
	);

	The Success Event handler will get a hash in ARG0:
	{
		'SQL'		=>	Original SQL inputted
		'RESULTS'	=>	Array of hash of rows ( array of fetchrow_hashref's )
		'PLACEHOLDERS'	=>	Original placeholders
	}

=item C<shutdown>

$_[KERNEL]->post( 'SimpleDBI', 'shutdown' );

This will signal SimpleDBI to start the shutdown procedure.

	NOTE: This will let all outstanding queries run!
	SimpleDBI will kill it's session when all the queries have been processed.

=item C<shutdown_NOW>

$_[KERNEL]->post( 'SimpleDBI', 'shutdown_NOW' );

	This will signal SimpleDBI to shutdown.

	NOTE: This will NOT let the outstanding queries finish!
	Any queries running will be lost!

=back

=head2 SimpleDBI Notes

	This module is very picky about capitalization!

	All of the options are uppercase, to avoid confusion.

	You can enable debugging mode by doing this:
	sub POE::Component::SimpleDBI::DEBUG () { 1 }
	use POE::Component::SimpleDBI;

	Also, this module will try to keep the SubProcess alive.
	if it dies, it will open it again for a max of 5 retries.

	You can override this behavior by doing this:
	sub POE::Component::SimpleDBI::MAX_RETRIES () { 10 }
	use POE::Component::SimpleDBI;

=head2 EXPORT

Nothing.

=head1 SEE ALSO

L<DBI>

L<POE>
L<POE::Wheel::Run>

L<POE::Component::DBIAgent>
L<POE::Component::LaDBI>

=head1 AUTHOR

Apocalypse E<lt>apocal@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2003 by Apocalypse

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut