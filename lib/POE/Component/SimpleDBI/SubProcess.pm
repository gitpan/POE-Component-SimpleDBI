# Declare our package
package POE::Component::SimpleDBI::SubProcess;

# Standard stuff to catch errors
use strict qw(subs vars refs);				# Make sure we can't mess up
use warnings FATAL => 'all';				# Enable warnings to catch errors

# Initialize our version
our $VERSION = '1.07';

# Use Error.pm's try/catch semantics
use Error qw( :try );

# We pass in data to POE::Filter::Reference
use POE::Filter::Reference;

# We run the actual DB connection here
use DBI;

# Our Filter object
our $filter = POE::Filter::Reference->new();

# Our DBI handle
our $DB = undef;

# Save the connect struct for future use
our $CONN = undef;

# Autoflush to avoid weirdness
$|++;

# Sysread error hits
my $sysreaderr = 0;

# This is the subroutine that will get executed upon the fork() call by our parent
sub main {
	# Okay, now we listen for commands from our parent :)
	while ( sysread( STDIN, my $buffer = '', 1024 ) ) {
		# Feed the line into the filter
		my $data = $filter->get( [ $buffer ] );

		# INPUT STRUCTURE IS:
		# $d->{'ACTION'}	= SCALAR	->	WHAT WE SHOULD DO
		# $d->{'SQL'}		= SCALAR	->	THE ACTUAL SQL
		# $d->{'PLACEHOLDERS'}	= ARRAY		->	PLACEHOLDERS WE WILL USE
		# $d->{'ID'}		= SCALAR	->	THE QUERY ID ( FOR PARENT TO KEEP TRACK OF WHAT IS WHAT )

		# $d->{'DSN'}		= SCALAR	->	DSN for CONNECT
		# $d->{'USERNAME'}	= SCALAR	->	USERNAME for CONNECT
		# $d->{'PASSWORD'}	= SCALAR	->	PASSWORD for CONNECT

		# Process each data structure
		foreach my $input ( @$data ) {
			# Now, we do the actual work depending on what kind of query it was
			if ( $input->{'ACTION'} eq 'CONNECT' ) {
				# Connect!
				DB_CONNECT( $input );
			} elsif ( $input->{'ACTION'} eq 'DISCONNECT' ) {
				# Disconnect!
				DB_DISCONNECT( $input );
			} elsif ( $input->{'ACTION'} eq 'DO' ) {
				# Fire off the SQL and return success/failure + rows affected
				DB_DO( $input );
			} elsif ( $input->{'ACTION'} eq 'SINGLE' ) {
				# Return a single result
				DB_SINGLE( $input );
			} elsif ( $input->{'ACTION'} eq 'MULTIPLE' ) {
				# Get many results, then return them all at the same time
				DB_MULTIPLE( $input );
			} elsif ( $input->{'ACTION'} eq 'QUOTE' ) {
				DB_QUOTE( $input );
			} elsif ( $input->{'ACTION'} eq 'EXIT' ) {
				# Cleanly disconnect from the DB
				if ( defined $DB ) { $DB->disconnect() }

				# EXIT!
				exit 0;
			} else {
				# Unrecognized action!
				output( Make_Error( $input->{'ID'}, 'Unknown action sent from parent' ) );
			}
		}
	}

	# Arrived here due to error in sysread/etc
	output( Make_Error( 'SYSREAD', $! ) );

	# If we got more than 5 sysread errors, abort!
	if ( ++$sysreaderr == 5 ) {
		if ( defined $DB ) { $DB->disconnect() }
		exit 0;
	} else {
		goto &main;
	}
}

# Connects to the DB
sub DB_CONNECT {
	# Get the input structure
	my $data = shift;

	# Our output structure
	my $output = undef;

	# Are we already connected?
	if ( defined $DB ) {
		# Output success
		$output = {
			'ID'	=>	$data->{'ID'},
		};
	} else {
		# Actually make the connection :)
		try {
			$DB = DBI->connect(
				# The DSN we just set up
				$data->{'DSN'},

				# Username
				$data->{'USERNAME'},

				# Password
				$data->{'PASSWORD'},

				# We set some configuration stuff here
				{
					# We do not want users seeing 'spam' on the commandline...
					'PrintError'	=>	0,

					# Automatically raise errors so we can catch them with try/catch
					'RaiseError'	=>	1,

					# Disable the DBI tracing
					'TraceLevel'	=>	0,
				}
			);

			# Check for undefined-ness
			if ( ! defined $DB ) {
				die "Error Connecting: $DBI::errstr";
			} else {
				# Output success
				$output = {
					'ID'	=>	$data->{'ID'},
				};

				# Save this!
				$CONN = $data;
			}
		} catch Error with {
			# Get the error
			my $e = shift;

			# Declare it!
			$output = Make_Error( $data->{'ID'}, $e );
		};
	}

	# All done!
	output( $output );
}

# Disconnects from the DB
sub DB_DISCONNECT {
	# Get the input structure
	my $data = shift;

	# Our output structure
	my $output = undef;

	# Are we already disconnected?
	if ( ! defined $DB ) {
		# Output success
		$output = {
			'ID'	=>	$data->{'ID'},
		};
	} else {
		# Disconnect from the DB
		try {
			$DB->disconnect();
			$DB = undef;

			# Output success
			$output = {
				'ID'	=>	$data->{'ID'},
			};
		} catch Error with {
			# Get the error
			my $e = shift;

			# Declare it!
			$output = Make_Error( $data->{'ID'}, $e );
		};
	}

	# All done!
	output( $output );
}

# This subroutine does a DB QUOTE
sub DB_QUOTE {
	# Get the input structure
	my $data = shift;

	# The result
	my $quoted = undef;
	my $output = undef;

	# Check if we are connected
	if ( ! defined $DB ) {
		$output = Make_Error( $data->{'ID'}, 'Not connected to the database!' );
	} else {
		# Quote it!
		try {
			$quoted = $DB->quote( $data->{'SQL'} );
		} catch Error with {
			# Get the error
			my $e = shift;

			$output = Make_Error( $data->{'ID'}, $e );
		};

		# Check for errors
		if ( ! defined $output ) {
			# Make output include the results
			$output = {};
			$output->{'DATA'} = $quoted;
			$output->{'ID'} = $data->{'ID'};
		}
	}

	# All done!
	output( $output );
}

# This subroutine runs a 'SELECT' style query on the db
sub DB_MULTIPLE {
	# Get the input structure
	my $data = shift;

	# Variables we use
	my $output = undef;
	my $sth = undef;
	my $result = [];

	# Check if we are connected
	if ( ! defined $DB ) {
		$output = Make_Error( $data->{'ID'}, 'Not connected to the database!' );
	} else {
		# Catch any errors :)
		try {
			# Make a new statement handler and prepare the query
			# We use the prepare_cached method in hopes of hitting a cached one...
			$sth = $DB->prepare_cached( $data->{'SQL'} );

			# Check for undef'ness
			if ( ! defined $sth ) {
				die "Did not get sth: $DBI::errstr";
			} else {
				# Execute the query
				try {
					# Put placeholders?
					if ( exists $data->{'PLACEHOLDERS'} ) {
						$sth->execute( @{ $data->{'PLACEHOLDERS'} } );
					} else {
						$sth->execute();
					}
				} catch Error with {
					die $sth->errstr;
				};
			}

			# The result hash
			my $newdata;

			# Bind the columns
			try {
				$sth->bind_columns( \( @$newdata{ @{ $sth->{'NAME_lc'} } } ) );
			} catch Error with {
				die $sth->errstr;
			};

			# Actually do the query!
			try {
				while ( $sth->fetch() ) {
					# Copy the data, and push it into the array
					push( @{ $result }, { %{ $newdata } } );
				}
			} catch Error with {
				die $sth->errstr;
			};

			# Check for any errors that might have terminated the loop early
			if ( $sth->err() ) {
				# Premature termination!
				die $sth->errstr;
			}
		} catch Error with {
			# Get the error
			my $e = shift;

			$output = Make_Error( $data->{'ID'}, $e );
		};

		# Check if we got any errors
		if ( ! defined $output ) {
			# Make output include the results
			$output = {};
			$output->{'DATA'} = $result;
			$output->{'ID'} = $data->{'ID'};
		}

		# Finally, we clean up this statement handle
		if ( defined $sth ) {
			$sth->finish();
		}
	}

	# Return the data structure
	output( $output );
}

# This subroutine runs a 'SELECT ... LIMIT 1' style query on the db
sub DB_SINGLE {
	# Get the input structure
	my $data = shift;

	# Variables we use
	my $output = undef;
	my $sth = undef;
	my $result = undef;

	# Check if we are connected
	if ( ! defined $DB ) {
		$output = Make_Error( $data->{'ID'}, 'Not connected to the database!' );
	} else {
		# Catch any errors :)
		try {
			# Make a new statement handler and prepare the query
			# We use the prepare_cached method in hopes of hitting a cached one...
			$sth = $DB->prepare_cached( $data->{'SQL'} );

			# Check for undef'ness
			if ( ! defined $sth ) {
				die "Did not get sth: $DBI::errstr";
			} else {
				# Execute the query
				try {
					# Put placeholders?
					if ( exists $data->{'PLACEHOLDERS'} ) {
						$sth->execute( @{ $data->{'PLACEHOLDERS'} } );
					} else {
						$sth->execute();
					}
				} catch Error with {
					die $sth->errstr;
				};
			}

			# Bind the columns
			try {
				$sth->bind_columns( \( @$result{ @{ $sth->{'NAME_lc'} } } ) );
			} catch Error with {
				die $sth->errstr;
			};

			# Actually do the query!
			try {
				$sth->fetch();
			} catch Error with {
				die $sth->errstr;
			};
		} catch Error with {
			# Get the error
			my $e = shift;

			$output = Make_Error( $data->{'ID'}, $e );
		};

		# Check if we got any errors
		if ( ! defined $output ) {
			# Make output include the results
			$output = {};
			$output->{'DATA'} = $result;
			$output->{'ID'} = $data->{'ID'};
		}

		# Finally, we clean up this statement handle
		if ( defined $sth ) {
			$sth->finish();
		}
	}

	# Return the data structure
	output( $output );
}

# This subroutine runs a 'DO' style query on the db
sub DB_DO {
	# Get the input structure
	my $data = shift;

	# Variables we use
	my $output = undef;
	my $sth = undef;
	my $rows_affected = undef;

	# Check if we are connected
	if ( ! defined $DB ) {
		$output = Make_Error( $data->{'ID'}, 'Not connected to the database!' );
	} else {
		# Catch any errors :)
		try {
			# Make a new statement handler and prepare the query
			# We use the prepare_cached method in hopes of hitting a cached one...
			$sth = $DB->prepare_cached( $data->{'SQL'} );

			# Check for undef'ness
			if ( ! defined $sth ) {
				die "Did not get sth: $DBI::errstr";
			} else {
				# Execute the query
				try {
					# Put placeholders?
					if ( exists $data->{'PLACEHOLDERS'} ) {
						$rows_affected = $sth->execute( @{ $data->{'PLACEHOLDERS'} } );
					} else {
						$rows_affected = $sth->execute();
					}
				} catch Error with {
					die $sth->errstr;
				};
			}
		} catch Error with {
			# Get the error
			my $e = shift;

			$output = Make_Error( $data->{'ID'}, $e );
		};

		# If rows_affected is not undef, that means we were successful
		if ( defined $rows_affected && ! defined $output ) {
			# Make the data structure
			$output = {};
			$output->{'DATA'} = $rows_affected;
			$output->{'ID'} = $data->{'ID'};
		} elsif ( ! defined $rows_affected && ! defined $output ) {
			# Internal error...
			die 'Internal Error in DB_DO';
		}

		# Finally, we clean up this statement handle
		if ( defined $sth ) {
			$sth->finish();
		}
	}

	# Return the data structure
	output( $output );
}

# This subroutine makes a generic error structure
sub Make_Error {
	# Make the structure
	my $data = {};
	$data->{'ID'} = shift;

	# Get the error, and stringify it in case of Error::Simple objects
	my $error = shift;

	if ( ref( $error ) && ref( $error ) eq 'Error::Simple' ) {
		$data->{'ERROR'} = $error->text;
	} else {
		$data->{'ERROR'} = $error;
	}

	# All done!
	return $data;
}

# Prints any output to STDOUT
sub output {
	# Get the data
	my $data = shift;

	# Freeze it!
	my $output = $filter->put( [ $data ] );

	# Print it!
	print STDOUT @$output;
}

# End of module
1;

__END__

=head1 NAME

POE::Component::SimpleDBI::SubProcess - Backend of POE::Component::SimpleDBI

=head1 ABSTRACT

This module is responsible for implementing the guts of POE::Component::SimpleDBI.
Namely, the fork/exec and the connection to the DBI.

=head2 EXPORT

Nothing.

=head1 SEE ALSO

L<POE::Component::SimpleDBI>

L<DBI>

L<POE>
L<POE::Wheel::Run>

L<POE::Component::DBIAgent>
L<POE::Component::LaDBI>

=head1 AUTHOR

Apocalypse E<lt>apocal@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2004 by Apocalypse

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut