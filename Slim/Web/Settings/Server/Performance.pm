package Slim::Web::Settings::Server::Performance;

# $Id: Performance.pm 31367 2010-09-21 14:48:19Z agrundman $

# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('server');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PERFORMANCE_SETTINGS');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('settings/server/performance.html');
}

sub prefs {
 	return ($prefs, qw(dbhighmem disableStatistics serverPriority scannerPriority resampleArtwork precacheArtwork maxPlaylistLength) );
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup) = @_;
	
	# Restart message if dbhighmem is changed
	my $curmem = $prefs->get('dbhighmem') || 0;
	if ( $paramRef->{pref_dbhighmem} && $paramRef->{pref_dbhighmem} != $curmem ) {
		# Trigger restart required message
		$paramRef = Slim::Web::Settings::Server::Plugins->getRestartMessage($paramRef, Slim::Utils::Strings::string('PLUGINS_CHANGED'));
	}
	
	# Restart if restart=1 param is set
	if ( $paramRef->{restart} ) {
		$paramRef = Slim::Web::Settings::Server::Plugins->restartServer($paramRef, 1);
	}

	$paramRef->{'options'} = {
		''   => 'SETUP_PRIORITY_CURRENT',
		map { $_ => {
			-16 => 'SETUP_PRIORITY_HIGH',
			 -6 => 'SETUP_PRIORITY_ABOVE_NORMAL',
			  0 => 'SETUP_PRIORITY_NORMAL',
			  5 => 'SETUP_PRIORITY_BELOW_NORMAL',
			  15 => 'SETUP_PRIORITY_LOW'
			}->{$_} } (-20 .. 20)
	};

	return $class->SUPER::handler($client, $paramRef, $pageSetup);
}

1;

__END__