package Slim::Player::SongStreamController;

# $Id: SongStreamController.pm 27975 2009-08-01 03:28:30Z andy $

# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use bytes;
use strict;
use warnings;

use Slim::Utils::Log;

my $log = logger('player.source');

my $_liveCount = 0;

sub new {
	my ($class, $song, $streamHandler) = @_;

	my $self = {
		song => $song,
		streamHandler => $streamHandler,
		protocolHandler => my $handler = Slim::Player::ProtocolHandlers->handlerForURL($song->streamUrl()),
	};

	bless $self, $class;
	
	$_liveCount++;
	if (main::DEBUGLOG && $log->is_debug) {
		$log->debug("live=$_liveCount");	
	}
	
	return $self;
}

sub DESTROY {
	my $self = shift;
	
	$self->close();
	
	$_liveCount--;
	if (main::DEBUGLOG && $log->is_debug)	{
		$log->debug("DESTROY($self) live=$_liveCount");
	}
}

sub song {return shift->{'song'};}
sub streamHandler {return shift->{'streamHandler'};}
sub protocolHandler {return shift->{'protocolHandler'};}

sub songProtocolHandler {return shift->song()->handler();}

sub close {
	my $self = shift;
	
	my $fd = $self->{'streamHandler'};
	
	if (defined $fd) {
		Slim::Networking::Select::removeError($fd);
		Slim::Networking::Select::removeRead($fd);
		$fd->close;
		delete $self->{'streamHandler'};
	}
}

sub isDirect {
	return shift->{'song'}->directstream() || 0;
}

sub streamUrl {
	return shift->{'song'}->streamUrl();
}

sub track {
	return shift->{'song'}->currentTrack();
}


1;