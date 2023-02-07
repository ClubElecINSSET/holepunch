#!/bin/bash

# Get username
USER=$1

# Get current folder
FOLDER=$(pwd)

# Add user
USEREXISTS=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep -c -E "/CN=$USER\$")
if [[ $USEREXISTS == '1' ]]; then
    exit 0
else
    cd /etc/openvpn/easy-rsa/ || return
    ./easyrsa --batch build-client-full "$USER" nopass
fi

cd "$FOLDER" || exit

# Generate client file
cp /etc/openvpn/client-template.txt "$FOLDER/$USER.ovpn"
{
    echo "<ca>"
    cat "/etc/openvpn/easy-rsa/pki/ca.crt"
    echo "</ca>"
    echo "<cert>"
    awk '/BEGIN/,/END CERTIFICATE/' "/etc/openvpn/easy-rsa/pki/issued/$USER.crt"
    echo "</cert>"
    echo "<key>"
    cat "/etc/openvpn/easy-rsa/pki/private/$USER.key"
    echo "</key>"
    echo "<tls-crypt>"
    cat /etc/openvpn/tls-crypt.key
    echo "</tls-crypt>"
} >>"$FOLDER/$USER.ovpn"
