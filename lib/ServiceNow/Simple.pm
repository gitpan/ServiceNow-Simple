package ServiceNow::Simple;
use strict;
use warnings FATAL => 'all';

our $VERSION = '0.01';

#use 5.010;      # We want to use state
use Data::Dumper;
use FindBin;
use HTTP::Cookies;
use HTTP::Request::Common;
use LWP::UserAgent;
use SOAP::Lite;
use XML::Simple;

$Data::Dumper::Indent=1;
$Data::Dumper::Sortkeys=1;

our %config;
my $user;
my $pword;

BEGIN
{
    my $module = 'ServiceNow/Simple.pm';
    my $cfg = $INC{$module};
    unless ($cfg)
    {
        die "Wrong case in use statement or $module module renamed. Perl is case sensitive!!!\n";
    }
    my $compiled = !(-e $cfg); # if the module was not read from disk => the script has been "compiled"
    $cfg =~ s/\.pm$/.cfg/;
    if ($compiled or -e $cfg)
    {
        # in a Perl2Exe or PerlApp created executable or PerlCtrl
        # generated COM object or the cfg is known to exist
        eval {require $cfg};
        if ($@ and $@ !~ /Can't locate /) #' <-- syntax higlighter
        {
            print STDERR "Error in $cfg : $@";
        }
    }
}


sub new
{
    my $proto = shift;
    my $class = ref($proto) || $proto;

    my $self = {};
    bless($self, $class);

    # Run initialisation code
    $self->_init(@_);

    return $self;
}


sub get
{
    my ($self, $args_h) = @_;

    my $method = $self->_get_method('get');
    my @params = $self->_load_args($args_h);
    my $result = $self->{soap}->call($method => @params);

    # Print faults to log file or stderr
    $self->_print_fault($result);

    if ($result && $result->body && $result->body->{'getResponse'})
    {
        return $result->body->{'getResponse'};
    }

    return;
}

sub get_keys
{
    my ($self, $args_h) = @_;

    my $method = $self->_get_method('getKeys');
    my @params = $self->_load_args($args_h);
    my $result = $self->{soap}->call($method => @params);

    # Print faults to log file or stderr
    $self->_print_fault($result);

# GG error checking here
    my $data_hr = $result->body->{'getKeysResponse'};

    if ($self->print_results())
    {
        print Data::Dumper->Dump([$data_hr], ['data_hr']) . "\n";
    }

    return $data_hr;
}


sub update
{
    # Note, one of the query_pairs must contain sys_id
    my ($self, $args_h) = @_;

    my $method = $self->_get_method('update');
    my @params = $self->_load_args($args_h);
    my $result = $self->{soap}->call($method => @params);

    # Print faults to log file or stderr
    $self->_print_fault($result);

    my $sys_id;
    if ($result && $result->body && $result->body->{updateResponse} && $result->body->{updateResponse}{sys_id})
    {
       $sys_id = $result->body->{updateResponse}{sys_id};
    }

    if ($self->print_results())
    {
        print Data::Dumper->Dump([$sys_id], ['sys_id']) . "\n";
    }

    return $sys_id;
}


sub get_records
{
    my ($self, $args_h) = @_;

    my $method = $self->_get_method('getRecords');

    # Check if we need to limit the columns returned.  Assume that IF there is a
    # __exclude_columns defined, it will over-ride this (and hence speed up the
    # process).  So __exclude_columns => undef is just a speed up, even though
    # there may be a LOT more data returned.
    if ($args_h->{__columns} && ! exists($args_h->{__exclude_columns}))
    {
        my $the_columns = $args_h->{__columns};
        delete $args_h->{__columns};

        if ($self->{__columns}{$self->{instance}}{$self->{table}}{$the_columns})
        {
            # We already have a list of fields to exclude for this form and __columns list
            $args_h->{__exclude_columns} = $self->{__columns}{$self->{instance}}{$self->{table}}{$the_columns};
        }
        else
        {
            # Do we have the list of fields for this form
            my @to_include = split /,/, $the_columns;
            my %all_fields;
            if ($self->{__columns}{__list}{$self->{instance}}{$self->{table}})
            {
                my $list = $self->{__columns}{__list}{$self->{instance}}{$self->{table}};
                %all_fields = map { $_ => 1 } split /,/, $list;
            }
            else
            {
                # Might as well query based on arguments passed, so remove what we don't want in query
                delete $args_h->{__exclude_columns};

                # Just get one record, to minimise data transfered
                my $original_limit = $args_h->{__limit};
                $args_h->{__limit} = 1;

                my @p = $self->_load_args($args_h);
                my $r = $self->{soap}->call($method => @p);

                # Add back in the limit if there was one, otherwise remove
                if ($original_limit)
                {
                    $args_h->{__limit} = $original_limit;
                }
                else
                {
                    delete $args_h->{__limit};
                }

                # GG handle no result!
                %all_fields = map { $_ => 1 } keys %{$r->body->{getRecordsResponse}{getRecordsResult}};

                # Store the full list in case we need it later
                $self->{__columns}{__list}{$self->{instance}}{$self->{table}} = join(',', keys %all_fields);
            }
            my @to_exclude;
            # Remove from the all fields hash those fields we want in the results
            # excluding the special meaning fields, those starting with '__'
            foreach my $ti (grep { $_ !~ /^__/} @to_include)
            {
                delete $all_fields{$ti};
            }

            # Add into the args we will pass
            $args_h->{__exclude_columns} = join(',', sort keys %all_fields);

            # Store for later use
            $self->{__columns}{$self->{instance}}{$self->{table}}{$the_columns} = $args_h->{__exclude_columns};
        }
    }

    my @params = $self->_load_args($args_h);
    my $result = $self->{soap}->call($method => @params);

    # Print faults to log file or stderr
    $self->_print_fault($result);


    my $data_hr;
    my $have_data = 0;
    if ($result && $result->body && $result->body->{getRecordsResponse} && $result->body->{getRecordsResponse}{getRecordsResult})
    {
        my $data = $result->body->{getRecordsResponse}{getRecordsResult};
        $have_data = 1;
        if (ref($data) eq 'HASH')
        {
            # There was only one record.  For consistant return, convert to array of hash
            $data_hr = { count => 1, rows => [ $data ] };
        }
        else
        {
            $data_hr = { count => scalar(@$data), rows => $data };
        }
    }

    if ($self->print_results() && $have_data)
    {
        print Data::Dumper->Dump([$data_hr], ['data_hr']) . "\n";
    }

    return $data_hr;
}


sub insert
{
    my ($self, $args_h) = @_;

    # Results:
    # --------
    # Regular tables:
    #   The sys_id field and the display value of the target table are returned.
    # Import set tables:
    #   The sys_id of the import set row, the name of the transformed target table (table),
    #   the display_name for the transformed target  table, the display_value of the
    #   transformed target row, and a status  field, which can contain inserted, updated,
    #   or error. There can be  an optional status_message field or an error_message field
    #   value when  status=error. When an insert did not cause a target row to be
    #   transformed, e.g. skipped because a key value is not specified, the sys_id field
    #   will contain the sys_id of the import set row rather than  the targeted transform table.
    # Import set tables with multiple transforms:
    #   The response from this type of insert will contain multiple sets of fields from the
    #   regular import set table insert wrapped in a multiInsertResponse parent element.
    #   Each set will contain a map field, showing which transform map created the response.

    my $method = $self->_get_method('insert');
    my @params = $self->_load_args($args_h);
    my $result = $self->{soap}->call($method => @params);

    # Print faults to log file or stderr
    $self->_print_fault($result);

    # insertResponse
    if ($result && $result->body && $result->body->{insertResponse})
    {
        return $result->body->{insertResponse};
    }

    return;
}



sub soap_debug
{
    SOAP::Lite->import(+trace => 'all');
}

sub print_results
{
    my ($self, $flag) = @_;

    if (defined $flag)
    {
        $self->{__print_results} = $flag;
    }
    return $self->{__print_results};
}


sub SOAP::Transport::HTTP::Client::get_basic_credentials
{
    return $user => $pword;
}


sub set_table
{
    my ($self, $table) = @_;

    $self->{table} = $table;
    $self->set_soap() if ($self->{instance});
    $self->_load_wsdl($table) unless $self->{wsdl}{$self->{instance}}{$table};
    # GG
    #print Dumper($self->{wsdl}{$self->{instance}}{$table}), "\n";
}


sub set_instance
{
    my ($self, $instance) = @_;

    $self->{instance} = $instance;
    $self->set_soap() if ($self->{table});
}


sub set_soap
{
    my ($self, $flag) = @_;

    my $url = 'https://' . $self->{instance} . '.service-now.com/' . $self->{table} . '.do?SOAP';

    # Do we need to show the display value for a reference field rather than the sys_id
    if ($flag || $self->{__display_value})
    {
        $url .=  '&displayvalue=true';
    }

    my %args = ( cookie_jar => HTTP::Cookies->new(ignore_discard => 1) ) ;
    if ($self->{proxy})
    {
        $args{https} = [ $self->{proxy} ];
    }

    $self->{soap} = SOAP::Lite->proxy($url, %args);
}


sub _get_method
{
    my ($self, $method) = @_;

    $self->{__fault} = undef;  # Clear any previous faults
    return SOAP::Data->name($method)->attr({xmlns => 'http://www.service-now.com/'});
}


sub _load_args
{
    my ($self, $args_h) = @_;
    my (@args, $k, $v);
    while (($k, $v) = each %$args_h)
    {
        push @args, SOAP::Data->name( $k => $v );
    }

    return @args;
}


sub _print_fault
{
    my ($self, $result) = @_;

    if ($result->fault)
    {
        no warnings qw(uninitialized);
        if ($self->{__log})
        {
            $self->{__log}->exp('E930 - faultcode   =' . $result->fault->{faultcode}   . "\n",
                                       'faultstring =' . $result->fault->{faultstring} . "\n",
                                       'detail      =' . $result->fault->{detail}      . "\n");
        }
        else
        {
            print STDERR 'faultcode   =' . $result->fault->{faultcode}   . "\n";
            print STDERR 'faultstring =' . $result->fault->{faultstring} . "\n";
            print STDERR 'detail      =' . $result->fault->{detail}      . "\n";
        }

        # Store the fault so it can be queried before the next ws call
        # Cleared in _get_method()
        $self->{__fault}{faultcode}   = $result->fault->{faultcode};
        $self->{__fault}{faultstring} = $result->fault->{faultstring};
        $self->{__fault}{detail}      = $result->fault->{detail};
    }
}


sub _load_wsdl
{
    my ($self, $table) = @_;

    my $ua = LWP::UserAgent->new();
    $ua->credentials($self->{instance} . '.service-now.com:443', 'Service-now', $user, $pword);
    my $response = $ua->get('https://' . $self->{instance} . '.service-now.com/' . $table . '.do?WSDL');
    if ($response->is_success())
    {
        #my $wsdl = XMLin($response->content, ForceArray => 1);
        #$XML::Simple::PREFERRED_PARSER = '';
        my $wsdl = XMLin($response->content);

        foreach my $method (grep { $_ !~ /Response$/ } keys %{ $wsdl->{'wsdl:types'}{'xsd:schema'}{'xsd:element'} })
        {
            #print "Method=$method\n";
            my $e = $wsdl->{'wsdl:types'}{'xsd:schema'}{'xsd:element'}{$method}{'xsd:complexType'}{'xsd:sequence'}{'xsd:element'};
            foreach my $fld (keys %{ $e })
            {
                #print "\n\n", join("\n", keys %{ $wsdl->{'wsdl:types'}{'xsd:schema'}{'xsd:element'}{deleteMultiple}{'xsd:complexType'}{'xsd:sequence'}{'xsd:element'} }), "\n";
                #print "  $fld => $e->{$fld}{type}\n";
                $self->{wsdl}{$self->{instance}}{$table}{$method}{$fld} = $e->{$fld};
            }
        }
    }
}


sub _init
{
    my ($self, $args) = @_;

    # Stop environment variable from playing around with SOAP::Lite
    undef($ENV{HTTP_proxy});
    undef($ENV{HTTPS_proxy});

    # Did we have any of the persistant variables passed
    my $k = '5Jv@sI9^bl@D*j5H3@:7g4H[2]d%Ks314aNuGeX;';
    if ($args->{user})
    {
        $self->{persistant}{user} = $args->{user};
    }
    else
    {
        my $s = pack('H*', $config{user});
        my $x = substr($k, 0, length($s));
        my $u = $s ^ $x;
        $self->{persistant}{user} = $u;
    }

    if ($args->{password})
    {
        $self->{persistant}{password} = $args->{password};
    }
    else
    {
        my $s = pack('H*', $config{password});
        my $x = substr($k, 0, length($s));
        my $u = $s ^ $x;
        $self->{persistant}{password} = $u;
    }
    if ($args->{proxy})
    {
        $self->{persistant}{proxy} = $config{proxy};
    }
    $user  = $self->{persistant}{user};
    $pword = $self->{persistant}{password};

    # Handle the other passed arguments
    $self->{__display_value} = $args->{__display_value} ? 1 : 0;
    $self->set_instance($args->{instance})              if $args->{instance};
    $self->set_table($args->{table})                    if $args->{table};     # Important this is after instance
    $self->{__limit}         = $args->{__limit}         if $args->{__limit};
    $self->{__log}           = $args->{__log}           if $args->{__log};
    $self->{__print_results} = $args->{__print_results} if $args->{__print_results};   # Print results to stdout
    $self->soap_debug()                                 if $args->{__soap_debug};
    if ($args->{table} && $args->{instance})
    {
        $self->set_soap();
    }
}

#####################################################################
# DO NOT REMOVE THE FOLLOWING LINE, IT IS NEEDED TO LOAD THIS LIBRARY
1;


__END__

=head1 NAME

ServiceNow::Simple - Simple yet powerful ServiceNow API interface

=head1 SYNOPSIS

B<Note:> To use the SOAP web services API the user you use must have
the appropriate 'soap' role(s) (there are a few) and the table/fields
must have access for the appropriate 'soap' role(s) if they are not open.
This is true, whether you use this module or other web services to interact
with ServiceNow.

There is a ServiceNow demonstration instance you can play with if you are unsure.
Try c<https://demo019.service-now.com/navpage.do> using user 'admin' with password
'admin'.  You will need to give the 'admin' user the 'soap' role and change the ACL
for sys_user_group to allow read and write for the 'soap' role (see the Wiki
C<http://wiki.servicenow.com/index.php?title=Main_Page> on how).  Tables that are open
do not need the ACL changes to allow access via these API's.

  use ServiceNow::Simple;

  ## Normal (minimal) use
  #######################
  my $sn = ServiceNow::Simple->new({ instance => 'some_name', table => 'sys_user' });
  # where your instance is https://some_name.service-now.com


  ## All options to new
  #####################
  my $sn = ServiceNow::Simple->new({
      instance        => 'some_name',
      table           => 'sys_user',
      __display_value => 1,            # Return the display value for a reference field
      __limit         => 23,           # Maximum records to return
      __log           => $log,         # Log to a File::Log object
      __print_results => 1,            # Print
      __soap_debug    => 1             # Print SOAP::Lite debug details
      });


  ## Get Keys
  ###########
  my $sn = ServiceNow::Simple->new({
      instance        => 'instance',
      table           => 'sys_user_group',
      user            => 'itil',
      password        => 'itil',
      });

  my $results = $sn->get_keys({ name => 'Administration' });
  # Single match:
  # $results = {
  #   'count' => '1',
  #   'sys_id' => '23105e1f1903ac00fb54sdb1ad54dc1a'
  # };

  $results = $sn->get_keys({ __encoded_query => 'GOTOnameSTARTSWITHa' });
  # Multi record match:
  # $results = {
  #   'count' => '6',
  #   'sys_id' => '23105e1f1903ac00fb54sdb1ad54dc1a,2310421b1cae0100e6ss837b1e7aa7d0,23100ed71cae0100e6ss837b1e7aa797,23100ed71cae0100e6ss837b1e7aa79d,2310421b1cae0100e6ss837b1e7aa7d4,231079c1b84ac5009c86fe3becceed2b'
  # };

  ## Insert a record
  ##################
  # Change table before insert
  $sn->set_table('sys_user');
  # Do the insert
  my $result = $sn->insert({
      user_name => 'GNG',
      name => 'GNG Test Record',
      active => 'true',
  });
  # Check the results, if there is an error $result will be undef
  if ($result)
  {
      print Dumper($result), "\n";
      # Sample success result:
      # $VAR1 = {
      #   'name' => 'GNG Test Record',
      #   'sys_id' => '2310f10bb8d4197740ff0d351492f271'
      # };
  }
  else
  {
      print Dumper($sn->{__fault}), "\n";
      # Sample failure result:
      # $VAR1 = {
      #   'detail' => 'com.glide.processors.soap.SOAPProcessingException: Insert Aborted : Error during insert of sys_user (GNG Test Record)',
      #   'faultcode' => 'SOAP-ENV:Server',
      #   'faultstring' => 'com.glide.processors.soap.SOAPProcessingException: Insert Aborted : Error during insert of sys_user (GNG Test Record)'
      # };
  }


  ## Get Records
  ##############
  my $sn = ServiceNow::Simple->new({
      instance => 'some_name',
      table    => 'sys_user_group',
      __print_results => 1,
      });
  my $results = $sn->get_records({ name => 'Administration', __columns => 'name,description' });
  # Sample as printed to stdout, __print_results (same as $results):
  # $data_hr = {
  #   'count' => 1,
  #   'rows' => [
  #     {
  #       'description' => 'Administrator group.',
  #       'name' => 'Administration'
  #     }
  #   ]
  # };

  # Encoded query with minimal returned fields
  $results = $sn->get_records({ __encoded_query => 'GOTOnameSTARTSWITHa', __columns => 'name,email' });
  # $results = {
  #   'count' => 2,
  #   'rows' => [
  #     {
  #       'email' => '',
  #       'name' => 'Administration'
  #     },
  #     {
  #       'email' => 'android_dev@my_org.com',
  #       'name' => 'Android'
  #     },
  #   ]
  # };


  ## Update
  #########
  my $r = $sn->update({
      sys_id => '97415d1f1903ac00fb54adb1ad54dc1a',    ## REQUIRED, sys_id must be provided
      active => 'true',                                #  Other field(s)
      });  # Administration group, which should always be defined, set 'Active' to true
  # $r eq '97415d1f1903ac00fb54adb1ad54dc1a'

  ## Change to another table
  ##########################
  $sn->set_table('sys_user');

  ## Change to another instance
  #############################
  $sn->set_instance('my_dev_instance');

  ## SOAP debug messages
  ##########################
  $sn->soap_debug(1);  # Turn on
  ... do something
  $sn->soap_debug(0);  # Turn off


=head1 STATUS

This is the initial release and is subject to change while more extensive testing is
carried out.  More documentation to follow.

=head1 MAIN METHODS

The set of methods that do things on ServiceNow and return useful information

=head2 new
=head2 get
=head2 get_keys
=head2 get_records
=head2 insert
=head2 update

=head1 RELATED METHODS

Allow you to change tables, instances, debug messages, printing etc

=head2 print_results
=head2 set_instance
=head2 set_soap
=head2 set_table
=head2 soap_debug

=head1 PRIVATE METHODS

Internal, you should not use, methods.  They may change without notice.

=head2 SOAP::Transport::HTTP::Client::get_basic_credentials
=head2 _get_method
=head2 _init
=head2 _load_args
=head2 _load_wsdl
=head2 _print_fault

=head1 USEFUL LINKS

 http://wiki.servicenow.com/index.php?title=Direct_Web_Services

 http://wiki.servicenow.com/index.php?title=Direct_Web_Service_API_Functions

=head1 VERSION

Version 0.01

=cut

=head1 AUTHOR

Greg George, C<< <gng at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-ServiceNow::Simple at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=ServiceNow::Simple>.
I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc ServiceNow::Simple

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=ServiceNow::Simple>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/ServiceNow::Simple>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/ServiceNow::Simple>

=item * Search CPAN

L<http://search.cpan.org/dist/ServiceNow::Simple/>

=back


=head1 ACKNOWLEDGEMENTS

The ServiceNow Wiki (see useful links), and authors of SOAP::Lite:

 Paul Kulchenko (paulclinger@yahoo.com)
 Randy J. Ray   (rjray@blackperl.com)
 Byrne Reese    (byrne@majordojo.com)
 Martin Kutter  (martin.kutter@fen-net.de)
 Fred Moyer     (fred@redhotpenguin.com)

=head1 LICENSE AND COPYRIGHT

Copyright 2013 Greg George.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut

# End of ServiceNow::Simple
#---< End of File >---#
