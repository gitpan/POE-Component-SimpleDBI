# Declare our package
package POE::Component::SimpleDBI::SubProcess;

# Standard stuff to catch errors
use strict qw(subs vars refs);				# Make sure we can't mess up
use warnings FATAL => 'all';				# Enable warnings to catch errors

# Initialize our version
our $VERSION = '1.03';

# Use Error.pm's try/catch semantics
use Error qw( :try );

# We pass in data to POE::Filter::Reference
use POE::Filter::Reference;

# We run the actual DB connection here
use DBI;

# Our Filter object
my $filter = POE::Filter::Reference->new();

# Autoflush to avoid weirdness
$|++;

# This is the subroutine that will get executed upon the fork() call by our parent
sub main {
	# Get our args
	my ( $DSN, $USERNAME, $PASSWORD ) = @_;

	# Database handle
	my $dbh;

	# Signify an error condition ( from the connection )
	my $error = undef;

	# Actually make the connection :)
	try {
		$dbh = DBI->connect(
			# The DSN we just set up
			$DSN,

			# Username
			$USERNAME,

			# Password
			$PASSWORD,

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
		if ( ! defined $dbh ) {
			die "Error Connecting: $DBI::errstr";
		}
	} catch Error with {
		# Get the error
		my $e = shift;

		# Declare it!
		output( Make_Error( 'DBI', $e ) );
		$error = 1;
	};

	# Catch errors!
	if ( $error ) {
		# QUIT
		return;
	}

	# Okay, now we listen for commands from our parent :)
	while ( sysread( STDIN, my $buffer = '', 1024 ) ) {
		# Feed the line into the filter
		my $data = $filter->get( [ $buffer ] );

		# INPUT STRUCTURE IS:
		# $d->{'ACTION'}	= SCALAR	->	WHAT WE SHOULD DO
		# $d->{'SQL'}		= SCALAR	->	THE ACTUAL SQL
		# $d->{'PLACEHOLDERS'}	= ARRAY		->	PLACEHOLDERS WE WILL USE
		# $d->{'ID'}		= SCALAR	->	THE QUERY ID ( FOR PARENT TO KEEP TRACK OF WHAT IS WHAT )

		# Process each data structure
		foreach my $input ( @$data ) {
			# Now, we do the actual work depending on what kind of query it was
			if ( $input->{'ACTION'} eq 'EXIT' ) {
				# Disconnect!
				$dbh->disconnect;
				return;
			} elsif ( $input->{'ACTION'} eq 'DO' ) {
				# Fire off the SQL and return success/failure + rows affected
				output( DB_DO( $dbh, $input ) );
			} elsif ( $input->{'ACTION'} eq 'SINGLE' ) {
				# Return a single result
				output( DB_SINGLE( $dbh, $input ) );
			} elsif ( $input->{'ACTION'} eq 'MULTIPLE' ) {
				# Get many results, then return them all at the same time
				output( DB_MULTIPLE( $dbh, $input ) );
			} elsif ( $input->{'ACTION'} eq 'QUOTE' ) {
				output( DB_QUOTE( $dbh, $input ) );
			} else {
				# Unrecognized action!
				output( Make_Error( $input->{'ID'}, 'Unknown action sent from parent' ) );
			}
		}
	}

	# Arrived here due to error in sysread/etc
	$dbh->disconnect;
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

# This subroutine does a DB QUOTE
sub DB_QUOTE {
	# Get the dbi handle
	my $dbh = shift;

	# Get the input structure
	my $data = shift;

	# The result
	my $quoted = undef;
	my $output = undef;

	# Quote it!
	try {
		$quoted = $dbh->quote( $data->{'SQL'} );
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

	# All done!
	return $output;
}

# This subroutine runs a 'SELECT' style query on the db
sub DB_MULTIPLE {
	# Get the dbi handle
	my $dbh = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $output = undef;
	my $sth = undef;
	my $result = [];

	# Check if this is a non-select statement
	if ( $data->{'SQL'} !~ /^SELECT/i ) {
		# User is not a SQL whiz, obviously ;)
		$output = Make_Error( $data->{'ID'}, "DB_MULTIPLE Is for SELECT queries only! ( $data->{'SQL'} )" );
		return $output;
	}

	# See if we have a 'LIMIT 1' in the end
	if ( $data->{'SQL'} =~ /LIMIT\s*\d*$/i ) {
		# Make sure it is NOT LIMIT 1
		if ( $data->{'SQL'} =~ /LIMIT\s*1$/i ) {
			# Not consistent with this interface
			$output = Make_Error( $data->{'ID'}, "DB_MULTIPLE -> LIMIT 1 is for DB_SINGLE! ( $data->{'SQL'} )" );
		}
	}

	# Catch any errors :)
	try {
		# Make a new statement handler and prepare the query
		# We use the prepare_cached method in hopes of hitting a cached one...
		$sth = $dbh->prepare_cached( $data->{'SQL'} );

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{'PLACEHOLDERS'} } );
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

	# Return the data structure
	return $output;
}

# This subroutine runs a 'SELECT ... LIMIT 1' style query on the db
sub DB_SINGLE {
	# Get the dbi handle
	my $dbh = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $output = undef;
	my $sth = undef;
	my $result = undef;

	# Check if this is a non-select statement
	if ( $data->{'SQL'} !~ /^SELECT/i ) {
		# User is not a SQL whiz, obviously ;)
		$output = Make_Error( $data->{'ID'}, "DB_SINGLE Is for SELECT queries only! ( $data->{'SQL'} )" );
		return $output;
	}

	# See if we have a 'LIMIT 1' in the end
	if ( $data->{'SQL'} =~ /LIMIT\s*\d*$/i ) {
		# Make sure it is LIMIT 1
		if ( $data->{'SQL'} !~ /LIMIT\s*1$/i ) {
			# Not consistent with this interface
			$output = Make_Error( $data->{'ID'}, "DB_SINGLE -> SQL must not have a LIMIT clause ( $data->{'SQL'} )" );
		}
	} else {
		# Insert 'LIMIT 1' to the string to give the database engine some hints...
		$data->{'SQL'} .= ' LIMIT 1';
	}

	# Catch any errors :)
	try {
		# Make a new statement handler and prepare the query
		# We use the prepare_cached method in hopes of hitting a cached one...
		$sth = $dbh->prepare_cached( $data->{'SQL'} );

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{'PLACEHOLDERS'} } );
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

	# Return the data structure
	return $output;
}

# This subroutine runs a 'DO' style query on the db
sub DB_DO {
	# Get the dbi handle
	my $dbh = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $output = undef;
	my $sth = undef;
	my $rows_affected = undef;

	# Check if this is a non-select statement
	if ( $data->{'SQL'} =~ /^SELECT/i ) {
		# User is not a SQL whiz, obviously ;)
		$output = Make_Error( $data->{'ID'}, "DB_DO Is for non-SELECT queries only! ( $data->{'SQL'} )" );
		return $output;
	}

	# Catch any errors :)
	try {
		# Make a new statement handler and prepare the query
		# We use the prepare_cached method in hopes of hitting a cached one...
		$sth = $dbh->prepare_cached( $data->{'SQL'} );

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$rows_affected = $sth->execute( $data->{'PLACEHOLDERS'} );
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
		$output->{'ROWS'} = $rows_affected;
		$output->{'ID'} = $data->{'ID'};
	} elsif ( ! defined $rows_affected && ! defined $output ) {
		# Internal error...
		die 'Internal Error in DB_DO';
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}

	# Return the data structure
	return $output;
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

Copyright 2003 by Apocalypse

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut