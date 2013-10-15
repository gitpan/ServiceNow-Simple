#!perl -T
#
# 01-get
#

use strict;
use warnings FATAL => 'all';
use Test::More;
use ServiceNow::Simple;

plan tests => 5;

sub BEGIN
{
	eval {require './t/config.cache'; };
	if ($@)
	{
		plan( skip_all => "Testing configuration was not set, test not possible" );
	}
}

my $sn = ServiceNow::Simple->new({ 
	instance => CCACHE::instance(), 
	user     => CCACHE::user(), 
	password => CCACHE::password(), 
	table    => 'sys_user_group', 
	});
ok( defined $sn);


my $results = $sn->get_keys({ name => 'CAB Approval' });
ok( defined $results);
ok( defined($results) && defined($results->{sys_id}));
print STDERR " 'CAB Approval' sys_id is " . $results->{sys_id} . "\n";

my $r = $sn->get({ sys_id => $results->{sys_id} });  # Administration group, which should always be defined
ok( defined $r);
ok( defined($r) && defined($r->{sys_id}));

# End