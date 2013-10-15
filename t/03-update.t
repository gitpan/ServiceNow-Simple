#!perl -T
#
# 03-update
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

my $r = $sn->update({ 
	sys_id => $results->{sys_id},
	active => 'true',
	});  # 'CAB Approval' group, which should always be defined, set 'Active' to true
ok( defined $r);
ok( $r eq $results->{sys_id});

# End