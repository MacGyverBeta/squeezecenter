package Slim::Networking::Async::Socket;

# $Id: Socket.pm 30446 2010-03-31 12:11:29Z agrundman $

# Squeezebox Server Copyright 2003-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

# A base class for all sockets

use strict;

# store data within the socket
sub set {
	my ( $self, $key, $val ) = @_;
	
	${*$self}{$key} = $val;
}

# pull data out of the socket
sub get {
	my ( $self, $key ) = @_;
	
	return ${*$self}{$key};
}

1;