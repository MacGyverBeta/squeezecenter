package Slim::Plugin::MyApps::Plugin;

# $Id: Plugin.pm 28826 2009-10-12 23:44:49Z andy $

use strict;
use base qw(Slim::Plugin::OPMLBased);

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		feed   => Slim::Networking::SqueezeNetwork->url( '/api/myapps/v1/opml' ),
		tag    => 'myapps',
		node   => 'home',
		weight => 80,
	);
}

# Don't add this item to any menu
sub playerMenu { }

1;