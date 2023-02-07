#!/bin/bash

IP=$(curl -s https://ifconfig.me)
PORT=443
PROTOCOL=tcp

# Get the "public" interface from the default route
NIC=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

# Install OpenVPN
apt-get install -y openvpn wget curl

# Install the latest version of easy-rsa from source
wget -O ~/easy-rsa.tgz https://github.com/OpenVPN/easy-rsa/releases/download/v3.1.2/EasyRSA-3.1.2.tgz
mkdir -p /etc/openvpn/easy-rsa
tar xzf ~/easy-rsa.tgz --strip-components=1 --no-same-owner --directory /etc/openvpn/easy-rsa
rm -f ~/easy-rsa.tgz
cd /etc/openvpn/easy-rsa/ || return
echo "set_var EASYRSA_ALGO ec" >/etc/openvpn/easy-rsa/pki/vars
echo "set_var EASYRSA_CURVE prime256v1" >>/etc/openvpn/easy-rsa/pki/vars

# Generate a random, alphanumeric identifier of 16 characters for CN and one for server name
SERVER_CN="cn_$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)"
SERVER_NAME="server_$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)"

# Create the PKI, set up the CA, the DH params and the server certificate
./easyrsa init-pki
./easyrsa --batch --req-cn="$SERVER_CN" build-ca nopass
./easyrsa --batch build-server-full "$SERVER_NAME" nopass
EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
openvpn --genkey --secret /etc/openvpn/tls-crypt.key

# Move all the generated files
cp pki/ca.crt pki/private/ca.key "pki/issued/$SERVER_NAME.crt" "pki/private/$SERVER_NAME.key" /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn

# Make cert revocation list readable for non-root
chmod 644 /etc/openvpn/crl.pem

# Generate server.conf
echo "port $PORT" >/etc/openvpn/server.conf
echo "proto $PROTOCOL" >>/etc/openvpn/server.conf
echo "dev tun
user nobody
group nogroup
persist-key
persist-tun
keepalive 10 120
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt" >>/etc/openvpn/server.conf
sed -ne 's/^nameserver[[:space:]]\+\([^[:space:]]\+\).*$/\1/p' '/etc/resolv.conf' | while read -r line; do
    echo "push \"dhcp-option DNS $line\"" >>/etc/openvpn/server.conf
done
echo "push \"redirect-gateway def1 bypass-dhcp\"
dh none
ecdh-curve prime256v1
tls-crypt tls-crypt.key
crl-verify crl.pem
ca ca.crt
cert $SERVER_NAME.crt
key $SERVER_NAME.key
auth SHA256
cipher AES-128-GCM
ncp-ciphers AES-128-GCM
tls-server
tls-version-min 1.2
tls-cipher TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256
client-config-dir /etc/openvpn/ccd
status /var/log/openvpn/status.log
verb 3" >>/etc/openvpn/server.conf

# Create client-config-dir dir
mkdir -p /etc/openvpn/ccd

# Create log dir
mkdir -p /var/log/openvpn

# Enable routing
echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-openvpn.conf

# Apply sysctl rules
sysctl --system

# Don't modify package-provided service
cp /lib/systemd/system/openvpn\@.service /etc/systemd/system/openvpn\@.service

# Workaround to fix OpenVPN service on OpenVZ
sed -i 's|LimitNPROC|#LimitNPROC|' /etc/systemd/system/openvpn\@.service

# Another workaround to keep using /etc/openvpn/
sed -i 's|/etc/openvpn/server|/etc/openvpn|' /etc/systemd/system/openvpn\@.service

systemctl daemon-reload
systemctl enable openvpn@server
systemctl restart openvpn@server

# Add iptables rules in two scripts
mkdir -p /opt/holepunch-openvpn-iptables

# Script to add rules
echo "#!/bin/sh
iptables -t nat -I POSTROUTING 1 -s 10.8.0.0/24 -o $NIC -j MASQUERADE
iptables -I INPUT 1 -i tun0 -j ACCEPT
iptables -I FORWARD 1 -i $NIC -o tun0 -j ACCEPT
iptables -I FORWARD 1 -i tun0 -o $NIC -j ACCEPT
iptables -I INPUT 1 -i $NIC -p $PROTOCOL --dport $PORT -j ACCEPT" >/opt/holepunch-openvpn-iptables/add-openvpn-rules.sh

# Script to remove rules
echo "#!/bin/sh
iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE
iptables -D INPUT -i tun0 -j ACCEPT
iptables -D FORWARD -i $NIC -o tun0 -j ACCEPT
iptables -D FORWARD -i tun0 -o $NIC -j ACCEPT
iptables -D INPUT -i $NIC -p $PROTOCOL --dport $PORT -j ACCEPT" >/opt/holepunch-openvpn-iptables/remove-openvpn-rules.sh

chmod +x /opt/holepunch-openvpn-iptables/add-openvpn-rules.sh
chmod +x /opt/holepunch-openvpn-iptables/remove-openvpn-rules.sh

# Handle the rules via a systemd script
echo "[Unit]
Description=iptables rules for OpenVPN
Before=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/opt/holepunch-openvpn-iptables/add-openvpn-rules.sh
ExecStop=/opt/holepunch-openvpn-iptables/remove-openvpn-rules.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target" >/etc/systemd/system/holepunch-openvpn-iptables.service

# Enable service and apply rules
systemctl daemon-reload
systemctl enable holepunch-openvpn-iptables
systemctl start holepunch-openvpn-iptables

# Generate a template for client
echo "client
proto tcp-client
remote $IP $PORT
dev tun
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name $SERVER_NAME name
auth SHA256
auth-nocache
cipher AES-128-GCM
tls-client
tls-version-min 1.2
tls-cipher TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256
ignore-unknown-option block-outside-dns
setenv opt block-outside-dns # Prevent Windows 10 DNS leak
verb 3" >>/etc/openvpn/client-template.txt
