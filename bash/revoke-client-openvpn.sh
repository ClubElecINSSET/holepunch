#!/bin/bash

# Get username
USER=$1

# Get current folder
FOLDER=$(pwd)

# Remove user
cd /etc/openvpn/easy-rsa/ || return
./easyrsa --batch revoke "$USER"
EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
rm -f /etc/openvpn/crl.pem
cp /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn/crl.pem
chmod 644 /etc/openvpn/crl.pem
rm "$FOLDER/$USER.ovpn"
sed -i "/^$USER,.*/d" /etc/openvpn/ipp.txt
cp /etc/openvpn/easy-rsa/pki/index.txt{,.bk}
exit
