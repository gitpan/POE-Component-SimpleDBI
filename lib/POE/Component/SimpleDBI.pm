# Declare our package
package POE::Component::SimpleDBI;

# Standard stuff to catch errors
use strict qw(subs vars refs);				# Make sure we can't mess up
use warnings FATAL => 'all';				# Enable warnings to catch errors

# Initialize our version
# $Revision: 1201 $
our $VERSION = '1.14';

# Import what we need from the POE namespace
use POE;			# For the constants
use POE::Session;		# To create our own :)
use POE::Filter::Reference;	# For communicating with the subprocess
use POE::Filter::Line;		# For subprocess STDERR messages
use POE::Wheel::Run;		# For the nitty-gritty details of 'fork'

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

	# Our own options
	my $ALIAS = shift;

	# Get the session alias
	if ( ! defined $ALIAS ) {
		# Debugging info...
		if ( DEBUG ) {
			warn 'Using default ALIAS = SimpleDBI';
		}

		# Set the default
		$ALIAS = 'SimpleDBI';
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
			'CONNECT'	=>	\&DB_CONNECT,
			'DISCONNECT'	=>	\&DB_DISCONNECT,

			# Queue stuff
			'Check_Queue'	=>	\&Check_Queue,
			'Clear_Queue'	=>	\&Clear_Queue,
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
			'DB_DSN'	=>	undef,
			'DB_USERNAME'	=>	undef,
			'DB_PASSWORD'	=>	undef,
			'DB_EVENT'	=>	undef,
			'DB_SESSION'	=>	undef,

			# Are we connected?
			'CONNECTED'	=>	0,

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
	if ( defined $_[ARG0] and $_[ARG0] eq 'NOW' ) {
		# Actually shut down!
		$_[HEAP]->{'SHUTDOWN'} = 2;

		# KILL our subprocess
		$_[HEAP]->{'WHEEL'}->kill( -9 );

		# Delete the wheel, so we have nothing to keep the GC from destructing us...
		delete $_[HEAP]->{'WHEEL'};

		# Clean up the queue
		$_[KERNEL]->call( $_[SESSION], 'Clear_Queue', 'SimpleDBI is shutting down now' );

		# Tell the kernel to kill us!
		$_[KERNEL]->signal( $_[SESSION], 'KILL' );
	} else {
		# Gracefully shut down...
		$_[HEAP]->{'SHUTDOWN'} = 1;

		# Put into the queue EXIT for the child
		push( @{ $_[HEAP]->{'QUEUE'} }, { 'ACTION' => 'EXIT', 'ID' => $_[HEAP]->{'IDCounter'}++ } );

		# Check if the subprocess is not active
		if ( ! $_[HEAP]->{'ACTIVE'} ) {
			# Send the query!
			$_[KERNEL]->call( $_[SESSION], 'Check_Queue' );
		}
	}
}

# This subroutine handles MULTIPLE + SINGLE + DO + QUOTE queries
sub DB_HANDLE {
	# Get the arguments
	my %args = @_[ARG0 .. $#_ ];

	# Check for unknown args
	foreach my $key ( keys %args ) {
		if ( $key !~ /^(?:SQL|PLACEHOLDERS|BAGGAGE|EVENT|SESSION)$/ ) {
			if ( DEBUG ) {
				warn "Unknown argument to $_[STATE] -> $key";
			}
			delete $args{ $key };
		}
	}

	# Add some stuff to the args
	$args{'ACTION'} = $_[STATE];
	if ( ! exists $args{'SESSION'} ) {
		$args{'SESSION'} = $_[SENDER]->ID();
	}

	# Check for Session
	if ( ! defined $args{'SESSION'} ) {
		# Nothing much we can do except drop this quietly...
		if ( DEBUG ) {
			warn "Did not receive a SESSION argument -> State: $_[STATE] Args: " . join( ' / ', %args ) . " Caller: " . $_[CALLER_FILE] . ' -> ' . $_[CALLER_LINE];
		}
		return;
	} else {
		if ( ref $args{'SESSION'} ) {
			if ( UNIVERSAL::isa( $args{'SESSION'}, 'POE::Session') ) {
				# Convert it!
				$args{'SESSION'} = $args{'SESSION'}->ID();
			} else {
				if ( DEBUG ) {
					warn "Received malformed SESSION argument -> State: $_[STATE] Args: " . join( ' / ', %args ) . " Caller: " . $_[CALLER_FILE] . ' -> ' . $_[CALLER_LINE];
				}
				return;
			}
		}
	}

	# Check for Event
	if ( ! exists $args{'EVENT'} ) {
		# Nothing much we can do except drop this quietly...
		if ( DEBUG ) {
			warn "Did not receive an EVENT argument -> State: $_[STATE] Args: " . join( ' / ', %args ) . " Caller: " . $_[CALLER_FILE] . ' -> ' . $_[CALLER_LINE];
		}
		return;
	} else {
		if ( ref $args{'EVENT'} ) {
			# Same quietness...
			if ( DEBUG ) {
				warn "Received a malformed EVENT argument -> State: $_[STATE] Args: " . join( ' / ', %args ) . " Caller: " . $_[CALLER_FILE] . ' -> ' . $_[CALLER_LINE];
			}
			return;
		}
	}

	# Check for SQL
	if ( ! exists $args{'SQL'} or ! defined $args{'SQL'} or ref $args{'SQL'} ) {
		# Extensive debug
		if ( DEBUG ) {
			warn 'Did not receive/malformed SQL string!';
		}

		# Okay, send the error to the Event
		$_[KERNEL]->post( $args{'SESSION'}, $args{'EVENT'}, {
			( exists $args{'SQL'} ? ( 'SQL' => $args{'SQL'} ) : () ),
			( exists $args{'PLACEHOLDERS'} ? ( 'PLACEHOLDERS' => $args{'PLACEHOLDERS'} ) : () ),
			( exists $args{'BAGGAGE'} ? ( 'BAGGAGE' => $args{'BAGGAGE'} ) : () ),
			'ERROR'		=>	'Received an empty/malformed SQL string!',
			'ACTION'	=>	$args{'ACTION'},
			'EVENT'		=>	$args{'EVENT'},
			'SESSION'	=>	$args{'SESSION'},
			}
		);
		return;
	}

	# Check for placeholders
	if ( exists $args{'PLACEHOLDERS'} ) {
		if ( ! ref $args{'PLACEHOLDERS'} or ref( $args{'PLACEHOLDERS'} ) ne 'ARRAY' ) {
			# Extensive debug
			if ( DEBUG ) {
				warn 'PLACEHOLDERS was not a ref to an ARRAY!';
			}

			# Okay, send the error to the Event
			$_[KERNEL]->post( $args{'SESSION'}, $args{'EVENT'}, {
				'SQL'		=>	$args{'SQL'},
				'PLACEHOLDERS'	=>	$args{'PLACEHOLDERS'},
				( exists $args{'BAGGAGE'} ? ( 'BAGGAGE' => $args{'BAGGAGE'} ) : () ),
				'ERROR'		=>	'PLACEHOLDERS is not an array!',
				'ACTION'	=>	$args{'ACTION'},
				'EVENT'		=>	$args{'EVENT'},
				'SESSION'	=>	$args{'SESSION'},
				}
			);
			return;
		}
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
			( exists $args{'PLACEHOLDERS'} ? ( 'PLACEHOLDERS' => $args{'PLACEHOLDERS'} ) : () ),
			( exists $args{'BAGGAGE'} ? ( 'BAGGAGE' => $args{'BAGGAGE'} ) : () ),
			'ERROR'		=>	'POE::Component::SimpleDBI is shutting down now, requests are not accepted!',
			'ACTION'	=>	$args{'ACTION'},
			'EVENT'		=>	$args{'EVENT'},
			'SESSION'	=>	$args{'SESSION'},
			}
		);
		return;
	}

	# Increment the refcount for the session that is sending us this query
	$_[KERNEL]->refcount_increment( $args{'SESSION'}, 'SimpleDBI' );

	# Add the ID to the query
	$args{'ID'} = $_[HEAP]->{'IDCounter'}++;

	# Add this query to the queue
	push( @{ $_[HEAP]->{'QUEUE'} }, \%args );

	# Check if the subprocess is not active
	if ( ! $_[HEAP]->{'ACTIVE'} ) {
		# Send the query!
		$_[KERNEL]->call( $_[SESSION], 'Check_Queue' );
	}

	# Return the ID for interested parties :)
	return $args{'ID'};
}

# This subroutine connects to the DB
sub DB_CONNECT {
	# Get the arguments
	my %args = @_[ARG0 .. $#_ ];

	# If we got no arguments, assume that we will use the old connection
	if ( keys %args == 0 ) {
		if ( ! exists $_[HEAP]->{'DB_DSN'} ) {
			# How should we connect?
			if ( DEBUG ) {
				warn 'Got CONNECT event but no arguments/did not have a cached copy of connect args';
			}
			return;
		}
	}

	# Check for unknown args
	foreach my $key ( keys %args ) {
		if ( $key !~ /^(?:SESSION|EVENT|DSN|USERNAME|PASSWORD|NOW|CLEAR)$/ ) {
			if ( DEBUG ) {
				warn "Unknown argument to CONNECT -> $key";
			}
			delete $args{ $key };
		}
	}

	# Add the cached copy if applicable
	foreach my $key ( qw( DSN USERNAME PASSWORD SESSION EVENT ) ) {
		if ( ! exists $args{ $key } and defined $_[HEAP]->{ 'DB_' . $key } ) {
			$args{ $key } = $_[HEAP]->{ 'DB_' . $key };
		}
	}

	# Add some stuff to the args
	$args{'ACTION'} = 'CONNECT';
	if ( ! exists $args{'SESSION'} ) {
		$args{'SESSION'} = $_[SENDER]->ID();
	}

	# Check for Session
	if ( ! defined $args{'SESSION'} ) {
		# Nothing much we can do except drop this quietly...
		if ( DEBUG ) {
			warn "Did not receive a SESSION argument -> State: CONNECT Args: " . join( ' / ', %args ) . " Caller: " . $_[CALLER_FILE] . ' -> ' . $_[CALLER_LINE];
		}
		return;
	} else {
		if ( ref $args{'SESSION'} ) {
			if ( UNIVERSAL::isa( $args{'SESSION'}, 'POE::Session') ) {
				# Convert it!
				$args{'SESSION'} = $args{'SESSION'}->ID();
			} else {
				if ( DEBUG ) {
					warn "Received malformed SESSION argument -> State: CONNECT Args: " . join( ' / ', %args ) . " Caller: " . $_[CALLER_FILE] . ' -> ' . $_[CALLER_LINE];
				}
				return;
			}
		}
	}

	# Check for Event
	if ( ! exists $args{'EVENT'} ) {
		# Nothing much we can do except drop this quietly...
		if ( DEBUG ) {
			warn "Did not receive an EVENT argument -> State: CONNECT Args: " . join( ' / ', %args ) . " Caller: " . $_[CALLER_FILE] . ' -> ' . $_[CALLER_LINE];
		}
		return;
	} else {
		if ( ref $args{'EVENT'} ) {
			# Same quietness...
			if ( DEBUG ) {
				warn "Received a malformed EVENT argument -> State: CONNECT Args: " . join( ' / ', %args ) . " Caller: " . $_[CALLER_FILE] . ' -> ' . $_[CALLER_LINE];
			}
			return;
		}
	}

	# Check the 3 things we are interested in
	foreach my $key ( qw( DSN USERNAME PASSWORD ) ) {
		# Check for it!
		if ( ! exists $args{ $key } or ! defined $args{ $key } or ref $args{ $key } ) {
			# Extensive debug
			if ( DEBUG ) {
				warn "Did not receive/malformed $key!";
			}

			# Okay, send the error to the Event
			$_[KERNEL]->post( $args{'SESSION'}, $args{'EVENT'}, {
				( exists $args{'DSN'} ? ( 'DSN' => $args{'DSN'} ) : () ),
				( exists $args{'USERNAME'} ? ( 'USERNAME' => $args{'USERNAME'} ) : () ),
				( exists $args{'PASSWORD'} ? ( 'PASSWORD' => $args{'PASSWORD'} ) : () ),
				'ERROR'		=>	"Cannot connect without the $key!",
				'ACTION'	=>	'CONNECT',
				'EVENT'		=>	$args{'EVENT'},
				'SESSION'	=>	$args{'SESSION'},
				}
			);
			return;
		}
	}

	# If we got CLEAR, empty the queue
	if ( exists $args{'CLEAR'} and $args{'CLEAR'} ) {
		$_[KERNEL]->call( $_[SESSION], 'Clear_Queue', 'The request queue was cleared via CONNECT' );
	}

	# Increment the refcount for the session that is sending us this query
	$_[KERNEL]->refcount_increment( $args{'SESSION'}, 'SimpleDBI' );

	# Add the ID to the query
	$args{'ID'} = $_[HEAP]->{'IDCounter'}++;

	# Are we connecting now?
	if ( exists $args{'NOW'} and $args{'NOW'} ) {
		# Add this query to the top of the queue

		# Save the old top query
		my $oldquery = shift( @{ $_[HEAP]->{'QUEUE'} } );

		# Add it to the top!
		unshift( @{ $_[HEAP]->{'QUEUE'} }, \%args );

		# Put the old one back on top if it was there
		if ( defined $oldquery ) {
			unshift( @{ $_[HEAP]->{'QUEUE'} }, $oldquery );
		}
	} else {
		# Add this to the bottom of the queue
		push( @{ $_[HEAP]->{'QUEUE'} }, \%args );
	}

	# Do we have the wheel running?
	if ( ! defined $_[HEAP]->{'WHEEL'} ) {
		# Create the wheel
		$_[KERNEL]->call( $_[SESSION], 'Setup_Wheel' );
	}

	# Check if the subprocess is not active + something in the queue
	if ( ! $_[HEAP]->{'ACTIVE'} and scalar( @{ $_[HEAP]->{'QUEUE'} } ) > 0 ) {
		# Send the query!
		$_[KERNEL]->call( $_[SESSION], 'Check_Queue' );
	}

	# Save the connection info
	foreach my $key ( qw( DSN USERNAME PASSWORD SESSION EVENT ) ) {
		$_[HEAP]->{ 'DB_' . $key } = $args{ $key };
	}

	# Return the ID for interested parties :)
	return $args{'ID'};
}

# This subroutine disconnects from the DB
sub DB_DISCONNECT {
	# Get the arguments
	my %args = @_[ARG0 .. $#_ ];

	# Check for unknown args
	foreach my $key ( keys %args ) {
		if ( $key !~ /^(?:SESSION|EVENT|NOW|CLEAR)$/ ) {
			if ( DEBUG ) {
				warn "Unknown argument to DISCONNECT -> $key";
			}
			delete $args{ $key };
		}
	}

	# Add some stuff to the args
	$args{'ACTION'} = 'DISCONNECT';
	if ( ! exists $args{'SESSION'} ) {
		$args{'SESSION'} = $_[SENDER]->ID();
	}

	# Check for Session
	if ( ! defined $args{'SESSION'} ) {
		# Nothing much we can do except drop this quietly...
		if ( DEBUG ) {
			warn "Did not receive a SESSION argument -> State: DISCONNECT Args: " . join( ' / ', %args ) . " Caller: " . $_[CALLER_FILE] . ' -> ' . $_[CALLER_LINE];
		}
		return;
	} else {
		if ( ref $args{'SESSION'} ) {
			if ( UNIVERSAL::isa( $args{'SESSION'}, 'POE::Session') ) {
				# Convert it!
				$args{'SESSION'} = $args{'SESSION'}->ID();
			} else {
				if ( DEBUG ) {
					warn "Received malformed SESSION argument -> State: DISCONNECT Args: " . join( ' / ', %args ) . " Caller: " . $_[CALLER_FILE] . ' -> ' . $_[CALLER_LINE];
				}
				return;
			}
		}
	}

	# Check for Event
	if ( ! exists $args{'EVENT'} ) {
		# Nothing much we can do except drop this quietly...
		if ( DEBUG ) {
			warn "Did not receive an EVENT argument -> State: DISCONNECT Args: " . join( ' / ', %args ) . " Caller: " . $_[CALLER_FILE] . ' -> ' . $_[CALLER_LINE];
		}
		return;
	} else {
		if ( ref $args{'EVENT'} ) {
			# Same quietness...
			if ( DEBUG ) {
				warn "Received a malformed EVENT argument -> State: DISCONNECT Args: " . join( ' / ', %args ) . " Caller: " . $_[CALLER_FILE] . ' -> ' . $_[CALLER_LINE];
			}
			return;
		}
	}

	# If we got CLEAR, empty the queue
	if ( exists $args{'CLEAR'} and $args{'CLEAR'} ) {
		$_[KERNEL]->call( $_[SESSION], 'Clear_Queue', 'The request queue was cleared via DISCONNECT' );
	}

	# Increment the refcount for the session that is sending us this query
	$_[KERNEL]->refcount_increment( $args{'SESSION'}, 'SimpleDBI' );

	# Add the ID to the query
	$args{'ID'} = $_[HEAP]->{'IDCounter'}++;

	# Are we disconnecting now?
	if ( exists $args{'NOW'} and $args{'NOW'} ) {
		# Add this query to the top of the queue

		# Save the old top query
		my $oldquery = shift( @{ $_[HEAP]->{'QUEUE'} } );

		# Add it to the top!
		unshift( @{ $_[HEAP]->{'QUEUE'} }, \%args );

		# Put the old one back on top if it was there
		if ( defined $oldquery ) {
			unshift( @{ $_[HEAP]->{'QUEUE'} }, $oldquery );
		}
	} else {
		# Add this to the bottom of the queue
		push( @{ $_[HEAP]->{'QUEUE'} }, \%args );
	}

	# Check if the subprocess is not active + something in the queue
	if ( ! $_[HEAP]->{'ACTIVE'} and scalar( @{ $_[HEAP]->{'QUEUE'} } ) > 0 ) {
		# Send the query!
		$_[KERNEL]->call( $_[SESSION], 'Check_Queue' );
	}

	# Return the ID for interested parties :)
	return $args{'ID'};
}

# This subroutine clears the queue
sub Clear_Queue {
	# Get the error string
	my $err = $_[ARG0];

	# If it is not defined, make it the default
	if ( ! defined $err ) {
		$err = 'Cleared the queue';
	}

	# Is the SubProcess active?
	my $activequeue = undef;
	if ( $_[HEAP]->{'ACTIVE'} ) {
		$activequeue = shift( @{ $_[HEAP]->{'QUEUE'} } );
	}

	# Go over our queue, and do some stuff
	foreach my $queue ( shift @{ $_[HEAP]->{'QUEUE'} } ) {
		# Skip the special EXIT actions we might have put on the queue
		if ( $queue->{'ACTION'} eq 'EXIT' ) { next }

		# Construct the response
		my $ret = {
			'ERROR'		=>	$err,
			'ACTION'	=>	$queue->{'ACTION'},
			'EVENT'		=>	$queue->{'EVENT'},
			'SESSION'	=>	$queue->{'SESSION'},
			'ID'		=>	$queue->{'ID'},
		};

		# Add needed fields
		if ( $queue->{'ACTION'} eq 'CONNECT' ) {
			$ret->{'DSN'} = $queue->{'DSN'};
			$ret->{'USERNAME'} = $queue->{'USERNAME'};
			$ret->{'PASSWORD'} = $queue->{'PASSWORD'};
		} elsif ( $queue->{'ACTION'} ne 'DISCONNECT' ) {
			$ret->{'SQL'} = $queue->{'SQL'};

			if ( exists $queue->{'PLACEHOLDERS'} ) {
				$ret->{'PLACEHOLDERS'} = $queue->{'PLACEHOLDERS'};
			}

			if ( exists $queue->{'BAGGAGE'} ) {
				$ret->{'BAGGAGE'} = $queue->{'BAGGAGE'};
			}
		}

		# Post a failure event to all the queries on the Queue, informing them that we have been shutdown...
		$_[KERNEL]->post( $queue->{'SESSION'}, $queue->{'EVENT'}, $ret );

		# Argh, decrement the refcount
		$_[KERNEL]->refcount_decrement( $queue->{'SESSION'}, 'SimpleDBI' );
	}

	# Clear the queue!
	$_[HEAP]->{'QUEUE'} = [];

	# Reinstate the active request if it exists
	if ( defined $activequeue ) {
		push( @{ $_[HEAP]->{'QUEUE'} }, $activequeue );
	}

	# All done!
	return 1;
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
			# Are we connected?
			if ( ! $_[HEAP]->{'CONNECTED'} ) {
				# Hmpf, maybe this query is the CONNECT one?
				if ( $_[HEAP]->{'QUEUE'}->[0]->{'ACTION'} ne 'CONNECT' ) {
					# WE ARE DEADLOCKED
					if ( DEBUG ) {
						warn "DEADLOCK -> Not connected, but $_[HEAP]->{'QUEUE'}->[0]->{'ACTION'} is on top of queue!";
					}
					return;
				}
			}

			# Extensive debug
			if ( DEBUG ) {
				warn "Sending a $_[HEAP]->{'QUEUE'}->[0]->{'ACTION'} query to the SubProcess";
			}

			# Copy what we need from the top of the queue
			my %queue;
			$queue{'ID'} = $_[HEAP]->{'QUEUE'}->[0]->{'ID'};
			$queue{'ACTION'} = $_[HEAP]->{'QUEUE'}->[0]->{'ACTION'};

			# CONNECT event?
			if ( $queue{'ACTION'} eq 'CONNECT' ) {
				$queue{'DSN'} = $_[HEAP]->{'QUEUE'}->[0]->{'DSN'};
				$queue{'USERNAME'} = $_[HEAP]->{'QUEUE'}->[0]->{'USERNAME'};
				$queue{'PASSWORD'} = $_[HEAP]->{'QUEUE'}->[0]->{'PASSWORD'};
			} elsif ( $queue{'ACTION'} ne 'DISCONNECT' ) {
				$queue{'SQL'} = $_[HEAP]->{'QUEUE'}->[0]->{'SQL'};

				if ( exists $_[HEAP]->{'QUEUE'}->[0]->{'PLACEHOLDERS'} ) {
					$queue{'PLACEHOLDERS'} = $_[HEAP]->{'QUEUE'}->[0]->{'PLACEHOLDERS'};
				}
			}

			# Set the child to 'active'
			$_[HEAP]->{'ACTIVE'} = 1;

			# Put it in the wheel
			$_[HEAP]->{'WHEEL'}->put( \%queue );
		} else {
			if ( DEBUG ) {
				warn 'Check_Queue was called but nothing in the queue!';
			}
		}
	} else {
		if ( DEBUG ) {
			warn 'Check_Queue was called but the SubProcess is active!';
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
		return undef;
	}

	# Check if the id exists + not at the top of the queue :)
	if ( defined @{ $_[HEAP]->{'QUEUE'} }[0] ) {
		if ( $_[HEAP]->{'QUEUE'}->[0]->{'ID'} eq $id ) {
			# Extensive debug
			if ( DEBUG ) {
				warn 'Could not delete query as it is being processed by the SubProcess!';
			}

			# Query is still active, nothing we can do...
			return 0;
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
		if ( DEBUG ) {
			warn 'Hmm, we are shutting down but got Setup_Wheel event...';
		}
		return;
	}

	# Check if we should set up the wheel
	if ( $_[HEAP]->{'Retries'} == MAX_RETRIES ) {
		die 'POE::Component::SimpleDBI tried ' . MAX_RETRIES . ' times to create a Wheel and is giving up...';
	}

	# Add the windows method
	if ( $^O eq 'MSWin32' ) {
		# Set up the SubProcess we communicate with
		$_[HEAP]->{'WHEEL'} = POE::Wheel::Run->new(
			# What we will run in the separate process
			'Program'	=>	\&POE::Component::SimpleDBI::SubProcess::main(),

			# Kill off existing FD's
			'CloseOnCall'	=>	0,

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
	} else {
		# Set up the SubProcess we communicate with
		$_[HEAP]->{'WHEEL'} = POE::Wheel::Run->new(
			# What we will run in the separate process
			'Program'	=>	"$^X -MPOE::Component::SimpleDBI::SubProcess -e 'POE::Component::SimpleDBI::SubProcess::main()'",

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
	}

	# Check for errors
	if ( ! defined $_[HEAP]->{'WHEEL'} ) {
		die 'Unable to create a new wheel!';
	} else {
		# Increment our retry count
		$_[HEAP]->{'Retries'}++;

		# We are not active...
		$_[HEAP]->{'ACTIVE'} = 0;

		# Since we created a new wheel, we have to tell it to connect if we already have the data
		if ( defined $_[HEAP]->{'DB_DSN'} ) {
			# Connect NOW!
			$_[KERNEL]->call( $_[SESSION], 'CONNECT', 'NOW' => 1 );
		}
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
		warn "POE::Component::SimpleDBI's Wheel died!";
	}

	# Get rid of the wheel
	undef $_[HEAP]->{'WHEEL'};

	# We are not active...
	$_[HEAP]->{'ACTIVE'} = 0;

	# Should we create it again?
	if ( ! $_[HEAP]->{'SHUTDOWN'} and $_[HEAP]->{'CONNECTED'} ) {
		# Create the wheel again
		$_[KERNEL]->call( $_[SESSION], 'Setup_Wheel' );
	} else {
		# We are disconnected!
		$_[HEAP]->{'CONNECTED'} = 0;
	}
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
	# The data!
	my $data = $_[ARG0];

	# Validate the argument
	if ( ! ref $data or ref( $data ) ne 'HASH' ) {
		warn "POE::Component::SimpleDBI did not get a hash from the SubProcess ( $data )";
		return;
	}

	# Special sysread error is here
	if ( $data->{'ID'} eq 'SYSREAD' ) {
		if ( DEBUG ) {
			warn "The backend got a SYSREAD error: $data->{'ERROR'}";
		}
		return;
	}

	# Special server discon error is here
	if ( $data->{'ID'} eq 'GONE' ) {
		if ( DEBUG ) {
			warn "The backend failed the \$dbh->ping test and couldn't reconnect!";
		}

		# We are now disconnected
		$_[HEAP]->{'CONNECTED'} = 0;
		$_[HEAP]->{'ACTIVE'} = 0;

		# Construct the response
		my $ret = {
			'ERROR'		=>	$data->{'ERROR'},
			'GONE'		=>	1,
			'DSN'		=>	$_[HEAP]->{'DB_DSN'},
			'USERNAME'	=>	$_[HEAP]->{'DB_USERNAME'},
			'PASSWORD'	=>	$_[HEAP]->{'DB_PASSWORD'},
		};

		# Okay, we have to inform the session it failed and couldn't reconnect
		$_[KERNEL]->post( $_[HEAP]->{'DB_SESSION'}, $_[HEAP]->{'DB_EVENT'}, $ret );

		# All done!
		return;
	}

	# Check to see if the ID matches with the top of the queue
	if ( $data->{'ID'} ne $_[HEAP]->{'QUEUE'}->[0]->{'ID'} ) {
		die "Internal error in queue/child consistency! ( CHILD: $data->{'ID'} QUEUE: $_[HEAP]->{'QUEUE'}->[0]->{'ID'}";
	}

	# Get the query from the top of the queue
	my $query = shift( @{ $_[HEAP]->{'QUEUE'} } );

	# If this was a connect/disconnect, update our status accordingly
	if ( $query->{'ACTION'} eq 'CONNECT' ) {
		# Did it succeed?
		if ( ! exists $data->{'ERROR'} ) {
			$_[HEAP]->{'CONNECTED'} = 1;
		}
	} elsif ( $query->{'ACTION'} eq 'DISCONNECT' ) {
		# Did it succeed?
		if ( ! exists $data->{'ERROR'} ) {
			$_[HEAP]->{'CONNECTED'} = 0;
		}
	}

	# Build the return hash
	my $ret = {
		'ACTION'	=>	$query->{'ACTION'},
		'ID'		=>	$data->{'ID'},
		'EVENT'		=>	$query->{'EVENT'},
		'SESSION'	=>	$query->{'SESSION'},
	};

	# Was this an error?
	if ( exists $data->{'ERROR'} ) {
		$ret->{'ERROR'} = $data->{'ERROR'};
	} else {
		$ret->{'RESULT'} = $data->{'DATA'};
	}

	# Add the extra fields
	if ( $query->{'ACTION'} eq 'CONNECT' ) {
		$ret->{'DSN'} = $query->{'DSN'};
		$ret->{'USERNAME'} = $query->{'USERNAME'};
		$ret->{'PASSWORD'} = $query->{'PASSWORD'};
	} elsif ( $query->{'ACTION'} ne 'DISCONNECT' ) {
		$ret->{'SQL'} = $query->{'SQL'};

		if ( exists $query->{'PLACEHOLDERS'} ) {
			$ret->{'PLACEHOLDERS'} = $query->{'PLACEHOLDERS'};
		}

		if ( exists $query->{'BAGGAGE'} ) {
			$ret->{'BAGGAGE'} = $query->{'BAGGAGE'};
		}
	}

	# Send the data to the appropriate place
	$_[KERNEL]->post( $query->{'SESSION'}, $query->{'EVENT'}, $ret );

	# Decrement the refcount for the session that sent us a query
	$_[KERNEL]->refcount_decrement( $query->{'SESSION'}, 'SimpleDBI' );

	# Now, that we have got a result, check if we need to send another query
	$_[HEAP]->{'ACTIVE'} = 0;
	if ( scalar( @{ $_[HEAP]->{'QUEUE'} } ) > 0 ) {
		$_[KERNEL]->call( $_[SESSION], 'Check_Queue' );
	}
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

POE::Component::SimpleDBI - Asynchronous non-blocking DBI calls in POE made simple

=head1 SYNOPSIS

	use POE;
	use POE::Component::SimpleDBI;

	# Create a new session with the alias we want
	POE::Component::SimpleDBI->new( 'SimpleDBI' ) or die 'Unable to create the DBI session';

	# Create our own session to communicate with SimpleDBI
	POE::Session->create(
		inline_states => {
			_start => sub {
				# Tell SimpleDBI to connect
				$_[KERNEL]->post( 'SimpleDBI', 'CONNECT',
					'DSN'		=>	'DBI:mysql:database=foobaz;host=192.168.1.100;port=3306',
					'USERNAME'	=>	'FooBar',
					'PASSWORD'	=>	'SecretPassword',
					'EVENT'		=>	'conn_handler',
				);

				# Execute a query and return number of rows affected
				$_[KERNEL]->post( 'SimpleDBI', 'DO',
					'SQL'		=>	'DELETE FROM FooTable WHERE ID = ?',
					'PLACEHOLDERS'	=>	[ qw( 38 ) ],
					'EVENT'		=>	'deleted_handler',
				);

				# Retrieve one row of information
				$_[KERNEL]->post( 'SimpleDBI', 'SINGLE',
					'SQL'		=>	'Select * from FooTable LIMIT 1',
					'EVENT'		=>	'success_handler',
					'BAGGAGE'	=>	'Some Stuff I want to keep!',
				);

				# We want many rows of information + get the query ID so we can delete it later
				my $id = $_[KERNEL]->call( 'SimpleDBI', 'MULTIPLE',
					'SQL'		=>	'SELECT foo, baz FROM FooTable2 WHERE id = ?',
					'PLACEHOLDERS'	=>	[ qw( 53 ) ],
					'EVENT'		=>	'multiple_handler',
				);

				# Quote something and send it to another session
				$_[KERNEL]->post( 'SimpleDBI', 'QUOTE',
					'SQL'		=>	'foo$*@%%sdkf"""',
					'SESSION'	=>	'OtherSession',
					'EVENT'		=>	'quote_handler',
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

			# Define your request handlers here
			'quote_handler'	=>	\&FooHandler,
			# And so on
		},
	);

=head1 ABSTRACT

	This module simplifies DBI usage in POE's multitasking world.

	This module is a breeze to use, you'll have DBI calls in your POE program
	up and running in only a few seconds of setup.

	This module does what XML::Simple does for the XML world.

	If you want more advanced usage, check out:
		POE::Component::LaDBI

=head1 DESCRIPTION

This module works its magic by creating a new session with POE, then spawning off a child process
to do the "heavy" lifting. That way, your main POE process can continue servicing other clients.
Queries are put into a queue, and processed one at a time.

The standard way to use this module is to do this:

	use POE;
	use POE::Component::SimpleDBI;

	POE::Component::SimpleDBI->new( ... );

	POE::Session->create( ... );

	POE::Kernel->run();

=head2 Starting SimpleDBI

To start SimpleDBI, just call it's new method:

	POE::Component::SimpleDBI->new( 'ALIAS' );

This method will die on error or return success.

NOTE: The act of starting/stopping SimpleDBI fires off _child events, read
the POE documentation on what to do with them :)

This constructor accepts only 1 argument: the alias. The default is "SimpleDBI".

=head2 Commands

There are a few commands you can trigger in SimpleDBI. They are triggered via $_[KERNEL]->post( ... );

=head3 ID

All of the commands except for Delete_Query and shutdown return an id. To get them, do this:
	my $id = $_[KERNEL]->call( 'SimpleDBI', ... );

Afterwards, the id can be used to delete queries, look at Delete_Query for more information.

=head3 Argument errors

All of the commands validate their arguments, and if an error happens ( missing argument, etc ), they will do either:
	- return undef and forget that your request even existed
	- post to the SESSION/EVENT with ERROR present in the data
		NOTE: The data will not have an ID key present

=head3 Explanation of DO/SINGLE/MULTIPLE/QUOTE arguments

They are passed in via the $_[KERNEL]->post( ... );

NOTE: Capitalization is very important!

=over 4

=item C<SQL>

This is the actual SQL line you want SimpleDBI to execute.
You can put in placeholders, this module supports them.

=item C<PLACEHOLDERS>

This is an array of placeholders.

You can skip this if your query does not utilize it.

=item C<SESSION>

This is the session that will get the result

You can skip this, it defaults to the sending session

=item C<EVENT>

This is the event, triggered whenever a query finished.

It will get a hash in ARG0, consult the specific queries on what you will get.

NOTE: If the key 'ERROR' exists in the hash, then it will contain the error string.

=item C<BAGGAGE>

This is a special argument, you can "attach" any kind of baggage to a query.
The baggage will be kept by SimpleDBI and returned to the Event handler intact.

This is good for storing data associated with a query like a client object, etc.

You can skip this if your query does not utilize it.

=back

=head3 C<CONNECT>

	This tells SimpleDBI to connect to the database

	NOTE: if we are already connected, it will be a success ( SimpleDBI will not disconnect then connect automatically )

	Accepted arguments:
		DSN		->	The DBI DSN string, consult the DBI docs on what this is
		USERNAME	->	The username for the connection
		PASSWORD	->	The password for the connection
		SESSION		->	The session to send the results
		EVENT		->	The event to send the results
		NOW		->	Tells SimpleDBI to bypass the queue and connect NOW!
		CLEAR		->	Tells SimpleDBI to clear the queue and connect NOW!

	NOTE: if the DSN/USERNAME/PASSWORD/SESSION/EVENT does not exist, SimpleDBI assumes you wanted to use
	the old connection and will use the cached values ( if you told it to DISCONNECT ).

	Here's an example on how to trigger this event:

	$_[KERNEL]->post( 'SimpleDBI', 'CONNECT',
		'DSN'		=>	'DBI:mysql:database=foobaz;host=192.168.1.100;port=3306',
		'USERNAME'	=>	'MyUser',
		'PASSWORD'	=>	'MyPassword',
		'EVENT'		=>	'conn_handler',
		'NOW'		=>	1,
	);

	The NOW/CLEAR arguments are special, they will tell SimpleDBI to bypass the request queue and connect NOW...
		The CLEAR argument will also delete all the requests waiting in the queue, they will get an ERROR result
		They both default to false, supply a boolean value to turn them on

	The Event handler will get a hash in ARG0:
	{
		'ERROR'		=>	exists only if an error occured
		'GONE'		=>	exists only if the server was disconnected and the reconnect failed
		'ACTION'	=>	'CONNECT'
		'ID'		=>	ID of the Query
		'EVENT'		=>	The event the query will respond to
		'SESSION'	=>	The session the query will respond to
	}

	Receiving this event without the ERROR key means SimpleDBI successfully connected and is waiting for queries

	NOTE: You can do nifty things like:
		$_[KERNEL]->post( 'SimpleDBI', 'CONNECT', 'DSN' => 'DBI:mysql:...', ... );
		$_[KERNEL]->post( 'SimpleDBI', 'DO', ... );
		$_[KERNEL]->post( 'SimpleDBI', 'SINGLE', ... );
		$_[KERNEL]->post( 'SimpleDBI', 'DISCONNECT' );
		$_[KERNEL]->post( 'SimpleDBI', 'CONNECT', 'DSN' => 'DBI:oracle:...', ... );
		$_[KERNEL]->post( 'SimpleDBI', 'MULTIPLE', ... );
		$_[KERNEL]->post( 'SimpleDBI', 'shutdown' );

	They all will be executed in the right order!

	As of 1.11 SimpleDBI now detects whether the backend lost the connection to the database server. The backend will
	automatically reconnect if it happens, but if that fails, an error will be sent to the session/event specified here
	with an extra key: 'GONE'. In this state SimpleDBI is deadlocked, any new queries will not be processed until a
	CONNECT NOW event is issued! Keep in mind the SINGLE/etc queries WILL NOT receive an error if this happens, the error
	goes straight to the CONNECT handler to keep it simple!

=head3 C<DISCONNECT>

	This tells SimpleDBI to disconnect from the database

	NOTE: In the case that a DISCONNECT is issued when we are not connected, it will still succeed...

	Accepted arguments:
		SESSION		->	The session to send the results
		EVENT		->	The event to send the results
		NOW		->	Tells SimpleDBI to bypass the queue and disconnect NOW!
		CLEAR		->	Tells SimpleDBI to clear the queue and disconnect NOW!

	Here's an example on how to trigger this event:

	$_[KERNEL]->post( 'SimpleDBI', 'DISCONNECT',
		'EVENT'		=>	'disconn_handler',
		'NOW'		=>	1,
	);

	The NOW/CLEAR arguments are special, they will tell SimpleDBI to bypass the request queue and connect NOW...
		The CLEAR argument will also delete all the requests waiting in the queue, they will get an ERROR result
		They both default to false, supply a boolean value to turn them on

	The Event handler will get a hash in ARG0:
	{
		'ERROR'		=>	exists only if an error occured
		'ACTION'	=>	'DISCONNECT'
		'ID'		=>	ID of the Query
		'EVENT'		=>	The event the query will respond to
		'SESSION'	=>	The session the query will respond to
	}

	Receiving this event without the ERROR key means SimpleDBI successfully disconnected

	BEWARE: There is the possibility of a deadlock:
		$_[KERNEL]->post( 'SimpleDBI', 'CONNECT', ... );
		$_[KERNEL]->post( 'SimpleDBI', 'MULTIPLE', ... );
		$_[KERNEL]->post( 'SimpleDBI', 'DISCONNECT' );
		$_[KERNEL]->post( 'SimpleDBI', 'DO', ... );
		$_[KERNEL]->post( 'SimpleDBI', 'SINGLE', ... );
		$_[KERNEL]->post( 'SimpleDBI', 'CONNECT' );

	In this case, the DO/SINGLE queries will NEVER run until you issue a CONNECT with NOW enabled

=head3 C<QUOTE>

	This simply sends off a string to be quoted, and gets it back.

	Accepted arguments:
		SESSION		->	The session to send the results
		EVENT		->	The event to send the results
		SQL		->	The string to be quoted
		BAGGAGE		->	Any extra data to keep associated with this query ( SimpleDBI will not touch it )

	Internally, it does this:

	return $dbh->quote( $SQL );

	Here's an example on how to trigger this event:

	$_[KERNEL]->post( 'SimpleDBI', 'QUOTE',
		SQL => 'foo$*@%%sdkf"""',
		EVENT => 'quote_handler',
	);

	The Event handler will get a hash in ARG0:
	{
		'ERROR'		=>	exists only if an error occured
		'ACTION'	=>	'QUOTE'
		'ID'		=>	ID of the Query
		'EVENT'		=>	The event the query will respond to
		'SESSION'	=>	The session the query will respond to
		'SQL'		=>	Original SQL inputted
		'RESULT'	=>	The quoted SQL
		'PLACEHOLDERS'	=>	Original placeholders ( may not exist if it was not provided )
		'BAGGAGE'	=>	whatever you set it to ( may not exist if it was not provided )
	}

=head3 C<DO>

	This query is specialized for those queries where you UPDATE/DELETE/INSERT/etc.

	THIS IS NOT FOR SELECT QUERIES!

	Accepted arguments:
		SESSION		->	The session to send the results
		EVENT		->	The event to send the results
		SQL		->	The string to be quoted
		PLACEHOLDERS	->	Any placeholders ( if needed )
		BAGGAGE		->	Any extra data to keep associated with this query ( SimpleDBI will not touch it )

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
		'ERROR'		=>	exists only if an error occured
		'ACTION'	=>	'DO'
		'ID'		=>	ID of the Query
		'EVENT'		=>	The event the query will respond to
		'SESSION'	=>	The session the query will respond to
		'SQL'		=>	Original SQL inputted
		'RESULT'	=>	Scalar value of rows affected
		'PLACEHOLDERS'	=>	Original placeholders ( may not exist if it was not provided )
		'BAGGAGE'	=>	whatever you set it to ( may not exist if it was not provided )
	}

=head3 C<SINGLE>

	This query is specialized for those queries where you will get exactly 1 result back.

	Accepted arguments:
		SESSION		->	The session to send the results
		EVENT		->	The event to send the results
		SQL		->	The string to be quoted
		PLACEHOLDERS	->	Any placeholders ( if needed )
		BAGGAGE		->	Any extra data to keep associated with this query ( SimpleDBI will not touch it )

	Keep in mind: the column names are all lowercased automatically!

	Internally, it does this:

	$sth = $dbh->prepare_cached( $SQL );
	$sth->execute( $PLACEHOLDERS );
	$result = $sth->fetchrow_hashref;
	return $result;

	Here's an example on how to trigger this event:

	$_[KERNEL]->post( 'SimpleDBI', 'SINGLE',
		SQL => 'Select * from FooTable',
		EVENT => 'success_handler',
		SESSION => 'MySession',
	);

	The Event handler will get a hash in ARG0:
	{
		'ERROR'		=>	exists only if an error occured
		'ACTION'	=>	'SINGLE'
		'ID'		=>	ID of the Query
		'EVENT'		=>	The event the query will respond to
		'SESSION'	=>	The session the query will respond to
		'SQL'		=>	Original SQL inputted
		'RESULT'	=>	Hash of columns - similar to fetchrow_hashref ( undef if no rows returned )
		'PLACEHOLDERS'	=>	Original placeholders ( may not exist if it was not provided )
		'BAGGAGE'	=>	whatever you set it to ( may not exist if it was not provided )
	}

=head3 C<MULTIPLE>

	This query is specialized for those queries where you will get more than 1 result back.

	Keep in mind: the column names are all lowercased automatically!

	Accepted arguments:
		SESSION		->	The session to send the results
		EVENT		->	The event to send the results
		SQL		->	The string to be quoted
		PLACEHOLDERS	->	Any placeholders ( if needed )
		BAGGAGE		->	Any extra data to keep associated with this query ( SimpleDBI will not touch it )

	Internally, it does this:

	$sth = $dbh->prepare_cached( $SQL );
	$sth->execute( $PLACEHOLDERS );
	$sth->bind_columns( %row );
	while ( $sth->fetch() ) {
		push( @results, { %row } );
	}
	return \@results;

	Here's an example on how to trigger this event:

	$_[KERNEL]->post( 'SimpleDBI', 'MULTIPLE',
		SQL => 'SELECT foo, baz FROM FooTable2 WHERE id = ?',
		EVENT => 'multiple_handler',
		PLACEHOLDERS => [ qw( 53 ) ],
	);

	The Event handler will get a hash in ARG0:
	{
		'ERROR'		=>	exists only if an error occured
		'ACTION'	=>	'MULTIPLE'
		'ID'		=>	ID of the Query
		'EVENT'		=>	The event the query will respond to
		'SESSION'	=>	The session the query will respond to
		'SQL'		=>	Original SQL inputted
		'RESULT'	=>	Array of hash of columns - similar to array of fetchrow_hashref's ( undef if no rows returned )
		'PLACEHOLDERS'	=>	Original placeholders ( may not exist if it was not provided )
		'BAGGAGE'	=>	whatever you set it to ( may not exist if it was not provided )
	}

=head3 C<Delete_Query>

	Call this event if you want to delete a query via the ID.

	Returns:
		undef if it wasn't able to find the ID
		0 if the query is currently being processed
		1 if the query was successfully deleted

	Here's an example on how to trigger this event:

	$_[KERNEL]->post( 'SimpleDBI', 'Delete_Query', $queryID );

	IF you really want to know the status, execute a call on the event and check the returned value.

=head3 C<Clear_Queue>

	This event will clear the entire queue except the running query, if there is one.

	You can also pass in one argument -> the error string to be used instead of the default, 'Cleared the queue'

	All the queries in the queue will return ERROR to their respective sessions/events

=head3 C<shutdown>

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

L<POE::Component::DBIAgent>

L<POE::Component::LaDBI>

L<POE::Component::EasyDBI>

=head1 AUTHOR

Apocalypse E<lt>apocal@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2006 by Apocalypse

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut