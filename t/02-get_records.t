#!perl -T
#
# 02-get_records
#

use strict;
use warnings FATAL => 'all';
use Test::More;
use ServiceNow::Simple;

sub BEGIN
{
	eval {require './t/config.cache'; };
	if ($@)
	{
		plan( skip_all => "Testing configuration was not set, test not possible" );
	}
}

plan tests => 3;

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

# End