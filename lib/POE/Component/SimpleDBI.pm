# Declare our package
package POE::Component::SimpleDBI;

# Standard stuff to catch errors
use strict qw(subs vars refs);				# Make sure we can't mess up
use warnings FATAL => 'all';				# Enable warnings to catch errors

# Initialize our version
our $VERSION = '1.08';

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

# Set some constants
BEGIN {
	# Debug fun!
	if ( ! defined &DEBUG ) {
		eval "sub DEBUG () { 0 }";
	}

	# Our own definition of the max retries
	if ( ! defined &MAX_RETRIES ) {
		eval "sub MAX_RETRIES () { 5 }";
	}
}

# Autoflush to avoid weirdness
$|++;

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
		if ( DEBUG ) {
			croak 'Unrecognized options were present in POE::Component::SimpleDBI->new -> ' . join( ', ', keys %opt );
		}
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
			'shutdown'	=>	\&Shutdown,

			# IO events
			'ChildError'	=>	\&ChildError,
			'ChildClosed'	=>	\&ChildClosed,
			'Got_STDOUT'	=>	\&Got_STDOUT,
			'Got_STDERR'	=>	\&Got_STDERR,

			# DB events
			'DO'		=>	\&DB_HANDLE,
			'SINGLE'	=>	\&DB_HANDLE,
			'MULTIPLE'	=>	\&DB_HANDLE,
			'QUOTE'		=>	\&DB_HANDLE,
			'_KILL'		=>	\&DB_HANDLE,

			# Queue stuff
			'Check_Queue'	=>	\&Check_Queue,
			'Delete_Query'	=>	\&Delete_Query,
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

# This subroutine handles shutdown signals
sub Shutdown {
	# Extensive debugging...
	if ( DEBUG ) {
		warn 'Initiating shutdown procedure!';
	}

	# Check for duplicate shutdown signals
	if ( $_[HEAP]->{'SHUTDOWN'} ) {
		# Okay, let's see what's going on
		if ( $_[HEAP]->{'SHUTDOWN'} == 1 && ! defined $_[ARG0] ) {
			# Duplicate shutdown events
			if ( DEBUG ) {
				warn 'Duplicate shutdown event was posted to SimpleDBI!';
			}
			return;
		} elsif ( $_[HEAP]->{'SHUTDOWN'} == 2 ) {
			# Tried to shutdown_NOW again...
			if ( DEBUG ) {
				warn 'Duplicate shutdown_NOW event was posted to SimpleDBI!';
			}
			return;
		}
	} else {
		# Remove our alias so we can be properly terminated
		$_[KERNEL]->alias_remove( $_[HEAP]->{'ALIAS'} );
	}

	# Check if we got "NOW"
	if ( defined $_[ARG0] && $_[ARG0] eq 'NOW' ) {
		# Actually shut down!
		$_[HEAP]->{'SHUTDOWN'} = 2;

		# KILL our subprocess
		$_[HEAP]->{'WHEEL'}->kill( -9 );

		# Delete the wheel, so we have nothing to keep the GC from destructing us...
		delete $_[HEAP]->{'WHEEL'};

		# Go over our queue, and do some stuff
		foreach my $queue ( @{ $_[HEAP]->{'QUEUE'} } ) {
			# Skip the special EXIT actions we might have put on the queue
			if ( $queue->{'ACTION'} eq 'EXIT' ) { next }

			# Post a failure event to all the queries on the Queue, informing them that we have been shutdown...
			$_[KERNEL]->post( $queue->{'SESSION'}, $queue->{'EVENT'}, {
				'SQL'		=>	$queue->{'SQL'},
				'PLACEHOLDERS'	=>	$queue->{'PLACEHOLDERS'},
				'ERROR'		=>	'POE::Component::SimpleDBI was shut down forcibly!',
				'ACTION'	=>	$queue->{'ACTION'},
				},
			);

			# Argh, decrement the refcount
			$_[KERNEL]->refcount_decrement( $queue->{'SESSION'}, 'SimpleDBI' );
		}

		# Tell the kernel to kill us!
		$_[KERNEL]->signal( $_[SESSION], 'KILL' );
	} else {
		# Gracefully shut down...
		$_[HEAP]->{'SHUTDOWN'} = 1;

		# Put into the queue EXIT for the child
		$_[KERNEL]->yield( '_KILL' );
	}
}

# This subroutine handles MULTIPLE + SINGLE + DO + QUOTE queries
sub DB_HANDLE {
	# Get the arguments
	my %args = @_[ARG0 .. $#_ ];

	# Check if we got the special KILL query
	if ( $_[STATE] ne '_KILL' ) {
		# Add some stuff to the args
		$args{'SESSION'} = $_[SENDER]->ID();
		$args{'ACTION'} = $_[STATE];

		# Check for Event
		if ( ! exists $args{'EVENT'} ) {
			# Nothing much we can do except drop this quietly...
			if ( DEBUG ) {
				warn "Did not receive an EVENT argument from caller " . $_[SESSION]->ID . " -> State: " . $_[STATE] . " Args: " . %args;
			}
			return;
		} else {
			if ( ref( $args{'EVENT'} ne 'SCALAR' ) ) {
				# Same quietness...
				if ( DEBUG ) {
					warn "Received an malformed EVENT argument from caller " . $_[SESSION]->ID . " -> State: " . $_[STATE] . " Args: " . %args;
				}
				return;
			}
		}

		# Check for SQL
		if ( ! exists $args{'SQL'} ) {
			# Extensive debug
			if ( DEBUG ) {
				warn 'Did not receive a SQL key!';
			}

			# Okay, send the error to the Event
			$_[KERNEL]->post( $args{'SESSION'}, $args{'EVENT'}, {
				'SQL'		=>	undef,
				'PLACEHOLDERS'	=>	undef,
				'ERROR'		=>	'SQL is not defined!',
				'ACTION'	=>	$args{'ACTION'},
				}
			);
			return;
		} else {
			if ( ref( $args{'SQL'} ) ) {
				# Extensive debug
				if ( DEBUG ) {
					warn 'SQL key was a reference!';
				}

				# Okay, send the error to the Event
				$_[KERNEL]->post( $args{'SESSION'}, $args{'EVENT'}, {
					'SQL'		=>	undef,
					'PLACEHOLDERS'	=>	undef,
					'ERROR'		=>	'SQL is not a scalar!',
					'ACTION'	=>	$args{'ACTION'},
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
				# Extensive debug
				if ( DEBUG ) {
					warn 'PLACEHOLDERS was not a ref to an ARRAY!';
				}

				# Okay, send the error to the Event
				$_[KERNEL]->post( $args{'SESSION'}, $args{'EVENT'}, {
					'SQL'		=>	$args{'SQL'},
					'PLACEHOLDERS'	=>	undef,
					'ERROR'		=>	'PLACEHOLDERS is not an array!',
					'ACTION'	=>	$args{'ACTION'},
					}
				);
				return;
			}
		}

		# Check for baggage
		if ( ! exists $args{'BAGGAGE'} ) {
			# Simply make it undef
			$args{'BAGGAGE'} = undef;
		}

		# Check if we have shutdown or not
		if ( $_[HEAP]->{'SHUTDOWN'} ) {
			# Extensive debug
			if ( DEBUG ) {
				warn 'Denied query due to SHUTDOWN';
			}

			# Do not accept this query
			$_[KERNEL]->post( $args{'SESSION'}, $args{'EVENT'}, {
				'SQL'		=>	$args{'SQL'},
				'PLACEHOLDERS'	=>	$args{'PLACEHOLDERS'},
				'ERROR'		=>	'POE::Component::SimpleDBI is shutting down now, requests are not accepted!',
				'ACTION'	=>	$args{'ACTION'},
				}
			);
			return;
		}

		# Increment the refcount for the session that is sending us this query
		$_[KERNEL]->refcount_increment( $_[SENDER]->ID(), 'SimpleDBI' );
	} else {
		# Prepare a KILL query :)
		$args{'ACTION'} = 'EXIT';
		$args{'SQL'} = undef;
		$args{'PLACEHOLDERS'} = undef;
	}

	# Add the ID to the query
	$args{'ID'} = $_[HEAP]->{'IDCounter'}++;

	# Add this query to the queue
	push( @{ $_[HEAP]->{'QUEUE'} }, \%args );

	# Send the query!
	$_[KERNEL]->call( $_[SESSION], 'Check_Queue' );

	# Return the ID for interested parties :)
	return $args{'ID'};
}

# This subroutine does the meat - sends queries to the subprocess
sub Check_Queue {
	# Extensive debug
	if ( DEBUG ) {
		warn 'Checking the queue for events to process';
	}

	# Check if the subprocess is currently active
	if ( ! $_[HEAP]->{'ACTIVE'} ) {
		# Check if we have a query in the queue
		if ( scalar( @{ $_[HEAP]->{'QUEUE'} } ) > 0 ) {
			# Extensive debug
			if ( DEBUG ) {
				warn 'Sending one query to the SubProcess';
			}

			# Copy what we need from the top of the queue
			my %queue;
			$queue{'ID'} = $_[HEAP]->{'QUEUE'}->[0]->{'ID'};
			$queue{'SQL'} = $_[HEAP]->{'QUEUE'}->[0]->{'SQL'};
			$queue{'ACTION'} = $_[HEAP]->{'QUEUE'}->[0]->{'ACTION'};
			$queue{'PLACEHOLDERS'} = $_[HEAP]->{'QUEUE'}->[0]->{'PLACEHOLDERS'};

			# Set the child to 'active'
			$_[HEAP]->{'ACTIVE'} = 1;

			# Put it in the wheel
			$_[HEAP]->{'WHEEL'}->put( \%queue );
		}
	}
}

# This subroutine deletes a query from the queue
sub Delete_Query {
	# ARG0 = ID
	my $id = $_[ARG0];

	# Validation
	if ( ! defined $id ) {
		# Debugging
		if ( DEBUG ) {
			warn 'Got a Delete_Query event with no arguments!';
		}
		return;
	}

	# Check if the id exists + not at the top of the queue :)
	if ( defined @{ $_[HEAP]->{'QUEUE'} }[0] ) {
		if ( @{ $_[HEAP]->{'QUEUE'} }[0]->{'ID'} eq $id ) {
			# Extensive debug
			if ( DEBUG ) {
				warn 'Could not delete query as it is being processed by the SubProcess!';
			}

			# Query is still active, nothing we can do...
			return undef;
		} else {
			# Search through the rest of the queue and see what we get
			foreach my $count ( @{ $_[HEAP]->{'QUEUE'} } ) {
				if ( $_[HEAP]->{'QUEUE'}->[ $count ]->{'ID'} eq $id ) {
					# Found a match, delete it!
					splice( @{ $_[HEAP]->{'QUEUE'} }, $count, 1 );

					# Return success
					return 1;
				}
			}
		}
	}

	# If we got here, we didn't find anything
	return undef;
}

# This starts the SimpleDBI
sub Start {
	# Extensive debug
	if ( DEBUG ) {
		warn 'Starting up SimpleDBI!';
	}

	# Set up the alias for ourself
	$_[KERNEL]->alias_set( $_[HEAP]->{'ALIAS'} );

	# Create the wheel
	$_[KERNEL]->yield( 'Setup_Wheel' );
}

# This sets up the WHEEL
sub Setup_Wheel {
	# Extensive debug
	if ( DEBUG ) {
		warn 'Attempting creation of SubProcess wheel now...';
	}

	# Are we shutting down?
	if ( $_[HEAP]->{'SHUTDOWN'} ) {
		# Do not re-create the wheel...
		return;
	}

	# Check if we should set up the wheel
	if ( $_[HEAP]->{'Retries'} == MAX_RETRIES ) {
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
		my ( $operation, $errnum, $errstr ) = @_[ ARG0 .. ARG2 ];
		warn "POE::Component::SimpleDBI got an $operation error $errnum: $errstr\n";
	}
}

# Handles child STDOUT output
sub Got_STDOUT {
	# Validate the argument
	if ( ref( $_[ARG0] ) ne 'HASH' ) {
		warn "POE::Component::SimpleDBI did not get a hash from the child ( $_[ARG0] )";
		return;
	}

	# Check for special DB messages with ID of 'DBI'
	if ( $_[ARG0]->{'ID'} eq 'DBI' ) {
		# Okay, we received a DBI error -> error in connection...

		# Shutdown ourself!
		$_[KERNEL]->call( $_[SESSION], 'shutdown', 'NOW' );

		# Too bad that we have to die...
		die( "Could not connect to the DataBase: $_[ARG0]->{'ERROR'}" );
	}

	# Check to see if the ID matches with the top of the queue
	if ( $_[ARG0]->{'ID'} ne @{ $_[HEAP]->{'QUEUE'} }[0]->{'ID'} ) {
		die "Internal error in queue/child consistency! ( CHILD: $_[ARG0]->{'ID'} QUEUE: @{ $_[HEAP]->{'QUEUE'} }[0]->{'ID'}";
	}

	# Get the query from the top of the queue
	my $query = shift( @{ $_[HEAP]->{'QUEUE'} } );

	# See if this is an error
	if ( exists $_[ARG0]->{'ERROR'} ) {
		# Send this to the Error handler
		$_[KERNEL]->post( $query->{'SESSION'}, $query->{'EVENT'}, {
			'SQL'		=>	$query->{'SQL'},
			'PLACEHOLDERS'	=>	$query->{'PLACEHOLDERS'},
			'ERROR'		=>	$_[ARG0]->{'ERROR'},
			'ACTION'	=>	$query->{'ACTION'},
			'BAGGAGE'	=>	$query->{'BAGGAGE'},
			}
		);
	} else {
		# Send the data to the appropriate place
		$_[KERNEL]->post( $query->{'SESSION'}, $query->{'EVENT'}, {
			'SQL'		=>	$query->{'SQL'},
			'PLACEHOLDERS'	=>	$query->{'PLACEHOLDERS'},
			'RESULT'	=>	$_[ARG0]->{'DATA'},
			'ACTION'	=>	$query->{'ACTION'},
			'BAGGAGE'	=>	$query->{'BAGGAGE'},
			}
		);
	}

	# Decrement the refcount for the session that sent us a query
	$_[KERNEL]->refcount_decrement( $query->{'SESSION'}, 'SimpleDBI' );

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
					EVENT => 'deleted_handler',
				);

				$_[KERNEL]->post( 'SimpleDBI', 'SINGLE',
					SQL => 'Select * from FooTable',
					EVENT => 'success_handler',
					BAGGAGE => 'Some Stuff I want to keep!',
				);

				my $id = $_[KERNEL]->call( 'SimpleDBI', 'MULTIPLE',
					SQL => 'SELECT foo, baz FROM FooTable2 WHERE id = ?',
					EVENT => 'multiple_handler',
					PLACEHOLDERS => [ qw( 53 ) ],
				);

				$_[KERNEL]->post( 'SimpleDBI', 'QUOTE',
					SQL => 'foo$*@%%sdkf"""',
					EVENT => 'quote_handler',
				);

				# Changed our mind!
				$_[KERNEL]->post( 'SimpleDBI', 'Delete_Query', $id );

				# 3 ways to shutdown

				# This will let the existing queries finish, then shutdown
				$_[KERNEL]->post( 'SimpleDBI', 'shutdown' );

				# This will terminate when the event traverses
				# POE's queue and arrives at SimpleDBI
				$_[KERNEL]->post( 'SimpleDBI', 'shutdown', 'NOW' );

				# Even QUICKER shutdown :)
				$_[KERNEL]->call( 'SimpleDBI', 'shutdown', 'NOW' );
			},

			success_handler => \&success_handler,
			deleted_handler => \&deleted_handler,
			quote_handler	=> \&quote_handler,
			multiple_handler => \&multiple_handler,
		},
	);

	sub quote_handler {
		# For QUOTE calls, we receive the scalar string of SQL quoted
		# $_[ARG0] = {
		#	SQL => The SQL You put in
		#	RESULT	=> scalar quoted SQL
		#	PLACEHOLDERS => The placeholders
		#	ACTION => QUOTE
		#	BAGGAGE => whatever you set it to
		# }

		if ( exists $_[ARG0]->{'ERROR'} ) {
			# Handle error here
		}
	}

	sub deleted_handler {
		# For DO calls, we receive the scalar value of rows affected
		# $_[ARG0] = {
		#	SQL => The SQL You put in
		#	RESULT	=> scalar value of rows affected
		#	PLACEHOLDERS => The placeholders
		#	ACTION => DO
		#	BAGGAGE => whatever you set it to
		# }

		if ( exists $_[ARG0]->{'ERROR'} ) {
			# Handle error here
		}
	}

	sub success_handler {
		# For SINGLE calls, we receive a hash ( similar to fetchrow_hash )
		# $_[ARG0] = {
		#	SQL => The SQL You put in
		#	RESULT	=> hash
		#	PLACEHOLDERS => The placeholders
		#	ACTION => SINGLE
		#	BAGGAGE => whatever you set it to
		# }

		if ( exists $_[ARG0]->{'ERROR'} ) {
			# Handle error here
		}
	}

	sub multiple_handler {
		# For MULTIPLE calls, we receive an array of hashes
		# $_[ARG0] = {
		#	SQL => The SQL You put in
		#	RESULT	=> array of hashes
		#	PLACEHOLDERS => The placeholders
		#	ACTION => MULTIPLE
		#	BAGGAGE => whatever you set it to
		# }

		if ( exists $_[ARG0]->{'ERROR'} ) {
			# Handle error here
		}
	}

=head1 ABSTRACT

	This module simplifies DBI usage in POE's multitasking world.

	This module is a breeze to use, you'll have DBI calls in your POE program
	up and running in only a few seconds of setup.

	This module does what XML::Simple does for the XML world.

	If you want more advanced usage, check out:
		POE::Component::LaDBI

	If you want even simpler usage, check out:
		POE::Component::DBIAgent

=head1 CHANGES

=head2 1.07 -> 1.08

	In the SubProcess, removed the select statement requirement

=head2 1.06 -> 1.07

	In the SubProcess, fixed a silly mistake in DO's execution of placeholders

	Cleaned up a few error messages in the SubProcess

	Peppered the code with *more* DEBUG statements :)

	Replaced a croak() with a die() when it couldn't connect to the database

	Documented the _child events

=head2 1.05 -> 1.06

	Fixed some typos in the POD

	Added the BAGGAGE option

=head2 1.04 -> 1.05

	Fixed some typos in the POD

	Fixed the DEBUG + MAX_RETRIES "Subroutine redefined" foolishness

=head2 1.03 -> 1.04

	Got rid of the EVENT_S and EVENT_E handlers, replaced with a single EVENT handler

	Internal changes to get rid of some stuff -> Send_Query / Send_Wheel

	Added the Delete_Query event -> Deletes an query via ID

	Changed the DO/MULTIPLE/SINGLE/QUOTE events to return an ID ( Only usable if call'ed )

	Made sure that the ACTION key is sent back to the EVENT handler every time

	Added some DEBUG stuff :)

	Added the CHANGES section

	Fixed some typos in the POD

=head2 1.02 -> 1.03

	Increments refcount for querying sessions so they don't go away

	POD formatting

	Consolidated shutdown and shutdown_NOW into one single event

	General formatting in program

	DB connection error handling

	Renamed the result hash: RESULTS to RESULT for better readability

	SubProcess -> added DBI connect failure handling

=head1 DESCRIPTION

This module works its magic by creating a new session with POE, then spawning off a child process
to do the "heavy" lifting. That way, your main POE process can continue servicing other clients.

The standard way to use this module is to do this:

	use POE;
	use POE::Component::SimpleDBI;

	POE::Component::SimpleDBI->new( ... );

	POE::Session->create( ... );

	POE::Kernel->run();

=head2 Starting SimpleDBI

To start SimpleDBI, just call it's new method:

	POE::Component::SimpleDBI->new(
		'ALIAS'		=>	'DataBase',
		'DSN'		=>	'DBI:mysql:database=foobaz;host=192.168.1.100;port=3306',
		'USERNAME'	=>	'DBLogin',
		'PASSWORD'	=>	'DBPass',
	);

This method will die on error or return success.

NOTE: If the SubProcess could not connect to the DB, it will return
an error, causing SimpleDBI to die.

NOTE: The act of starting/stopping SimpleDBI fires off _child events, read
the POE documentation on what to do with them :)

This constructor accepts only 4 different options.

=over 4

=item C<ALIAS>

This will set the alias SimpleDBI uses in the POE Kernel.
This will default TO "SimpleDBI"

=item C<DSN>

This is the DSN -> Database connection string

SimpleDBI expects this to contain everything you need to connect to a database
via DBI, sans the username and password.

For valid DSN strings, consult your DBI manual.

=item C<USERNAME>

Simply put, this is the DB username SimpleDBI will use.

=item C<PASSWORD>

Simply put, this is the DB password SimpleDBI will use.

=back

=head2 Events

There is a few events you can trigger in SimpleDBI.
They all share a common argument format, except for the shutdown and Delete_Query event.

=over 4

=item C<QUOTE>

	This simply sends off a string to be quoted, and gets it back.

	Internally, it does this:

	return $dbh->quote( $SQL );

	Here's an example on how to trigger this event:

	$_[KERNEL]->post( 'SimpleDBI', 'QUOTE',
		SQL => 'foo$*@%%sdkf"""',
		EVENT => 'quote_handler',
	);

	The Event handler will get a hash in ARG0:
	{
		'SQL'		=>	Original SQL inputted
		'RESULT'	=>	The quoted SQL
		'PLACEHOLDERS'	=>	Original placeholders
		'ACTION'	=>	'QUOTE'
		'ERROR'		=>	exists only if an error occured
		'BAGGAGE'	=>	whatever you set it to
	}

	Note: It will return the internal query ID if you store the return value via call:
	my $queryid = $_[KERNEL]->call( ... );

	Look at Delete_Query for what you can do with the ID.

=item C<DO>

	This query is specialized for those queries where you UPDATE/DELETE/INSERT/etc.

	THIS IS NOT FOR SELECT QUERIES!

	Internally, it does this:

	$sth = $dbh->prepare_cached( $SQL );
	$rows_affected = $sth->execute( $PLACEHOLDERS );
	return $rows_affected;

	Here's an example on how to trigger this event:

	$_[KERNEL]->post( 'SimpleDBI', 'DO',
		SQL => 'DELETE FROM FooTable WHERE ID = ?',
		PLACEHOLDERS => [ qw( 38 ) ],
		EVENT => 'deleted_handler',
	);

	The Event handler will get a hash in ARG0:
	{
		'SQL'		=>	Original SQL inputted
		'RESULT'	=>	Scalar value of rows affected
		'PLACEHOLDERS'	=>	Original placeholders
		'ACTION'	=>	'DO'
		'ERROR'		=>	exists only if an error occured
		'BAGGAGE'	=>	whatever you set it to
	}

	Note: It will return the internal query ID if you store the return value via call:
	my $queryid = $_[KERNEL]->call( ... );

	Look at Delete_Query for what you can do with the ID.

=item C<SINGLE>

	This query is specialized for those queries where you will get exactly 1 result back.

	Keep in mind: the column names are all lowercased automatically!

	NOTE: This subroutine will automatically append ' LIMIT 1' to all queries passed in.

	Internally, it does this:

	$sth = $dbh->prepare_cached( $SQL );
	$sth->execute( $PLACEHOLDERS );
	$sth->bind_columns( %result );
	$sth->fetch();
	return %result;

	Here's an example on how to trigger this event:

	$_[KERNEL]->post( 'SimpleDBI', 'SINGLE',
		SQL => 'Select * from FooTable',
		EVENT => 'success_handler',
	);

	The Event handler will get a hash in ARG0:
	{
		'SQL'		=>	Original SQL inputted
		'RESULT'	=>	Hash of rows - similar to fetchrow_hashref
		'PLACEHOLDERS'	=>	Original placeholders
		'ACTION'	=>	'SINGLE'
		'ERROR'		=>	exists only if an error occured
		'BAGGAGE'	=>	whatever you set it to
	}

	Note: It will return the internal query ID if you store the return value via call:
	my $queryid = $_[KERNEL]->call( ... );

	Look at Delete_Query for what you can do with the ID.

=item C<MULTIPLE>

	This query is specialized for those queries where you will get more than 1 result back.

	Keep in mind: the column names are all lowercased automatically!

	Internally, it does this:

	$sth = $dbh->prepare_cached( $SQL );
	$sth->execute( $PLACEHOLDERS );
	$sth->bind_columns( %row );
	while ( $sth->fetch() ) {
		push( @results, %row );
	}
	return @results;

	Here's an example on how to trigger this event:

	$_[KERNEL]->post( 'SimpleDBI', 'MULTIPLE',
		SQL => 'SELECT foo, baz FROM FooTable2 WHERE id = ?',
		EVENT => 'multiple_handler',
		PLACEHOLDERS => [ qw( 53 ) ],
	);

	The Event handler will get a hash in ARG0:
	{
		'SQL'		=>	Original SQL inputted
		'RESULT'	=>	Array of hash of rows ( array of fetchrow_hashref's )
		'PLACEHOLDERS'	=>	Original placeholders
		'ACTION'	=>	'MULTIPLE'
		'ERROR'		=>	exists only if an error occured
		'BAGGAGE'	=>	whatever you set it to
	}

	Note: It will return the internal query ID if you store the return value via call:
	my $queryid = $_[KERNEL]->call( ... );

	Look at Delete_Query for what you can do with the ID.

=item C<Delete_Query>

	Call this event if you want to delete a query via the ID.

	Returns:
		undef if it wasn't able to find the ID
		undef if the query is currently being processed
		true if the query was successfully deleted

	Here's an example on how to trigger this event:

	$_[KERNEL]->post( 'SimpleDBI', 'Delete_Query', $queryID );

	IF you really want to know the status, execute a call on the event and check the returned value.

=item C<Shutdown>

	$_[KERNEL]->post( 'SimpleDBI', 'shutdown' );

	This will signal SimpleDBI to start the shutdown procedure.

	NOTE: This will let all outstanding queries run!
	SimpleDBI will kill it's session when all the queries have been processed.

	you can also specify an argument:

	$_[KERNEL]->post( 'SimpleDBI', 'shutdown', 'NOW' );

	This will signal SimpleDBI to shutdown.

	NOTE: This will NOT let the outstanding queries finish!
	Any queries running will be lost!

	Due to the way POE's queue works, this shutdown event will take some time to propagate POE's queue.
	If you REALLY want to shut down immediately, do this:

	$_[KERNEL]->call( 'SimpleDBI', 'shutdown', 'NOW' );

=back

=head3 Arguments

They are passed in via the $_[KERNEL]->post( ... );

NOTE: Capitalization is very important!

=over 4

=item C<SQL>

This is the actual SQL line you want SimpleDBI to execute.
You can put in placeholders, this module supports them.

=item C<PLACEHOLDERS>

This is an array of placeholders.

You can skip this if your query does not utilize it.

=item C<EVENT>

This is the event, triggered whenever a query finished.

It will get a hash in ARG0, consult the specific queries on what you will get.

NOTE: If the key 'ERROR' exists in the hash, then it will contain the error string.

=item C<BAGGAGE>

This is a special argument, you can "attach" any kind of baggage to a query.
The baggage will be kept by SimpleDBI and returned to the Event handler intact.

This is good for storing data associated with a query like a client object, etc.

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