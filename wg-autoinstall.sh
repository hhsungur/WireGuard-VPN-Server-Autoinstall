#!/bin/bash

if [ "$(whoami)" != "root" ]; then
	echo "This script must be run as root"
	exit
fi

EVERYTHINGISOK="/etc/wireguard/wg0.conf"

if [ ! -e /dev/net/tun ]; then
	echo "We need the TUN device for wireguard. Please enable TUN and run this shitcript again!"
	exit
fi

if [ -e /etc/centos-release ]; then
	DIST="CentOS"
elif [ -e /etc/debian_version ]; then
	apt update
	apt install lsb-release -y
	DIST=$( lsb_release -is)
else
	echo "Maybe you wanna install the popular releases like Ubuntu, Debian or CentOS :-/"
	exit
fi

function random_port
{
    local rand_port=$(shuf -i 2000-65000 -n 1)
    ss -lau | grep $rand_port > /dev/null
    if [[ $? == 1 ]] ; then
        echo "$port"
    else
        random_port
    fi
}

if [ ! -e "$EVERYTHINGISOK" ]; then
	INTERACTIVE=${INTERACTIVE:-yes}
	PRIVATE_SUBNET=${PRIVATE_SUBNET:-"10.9.0.0/24"}
	PRIVATE_SUBNET_MASK=$( echo $PRIVATE_SUBNET | cut -d "/" -f 2 )
	GATEWAY_ADDRESS="${PRIVATE_SUBNET::-4}1"
	
	if [ "$IP" == "" ]; then
		IP=$(curl ip.mtak.nl -4)
		if [ "$INTERACTIVE" == "yes" ]; then
			read -p "Public IP Address is: $IP. Is this true? [y/n]: " -e -i "y" CONFIRM
			
			if [ "$CONFIRM" == "n" ]; then
				read -p "Please enter your server's public IP address: " -e -i "$IP" IP
			fi
		fi
	fi
	
	if [ "$PORT" == "" ]; then
		read -p "Do you want to use port 443 (UDP)? [y/n]" -e -i "y" CONFIRM2
		if [ "$CONFIRM2" == "y" ]; then
			PORT="443"
		else
			PORT=$(random_port)
		fi
	fi
	
	if [ "$DNS" == "" ]; then
		read -p "Do you want to use CloudFlare DNS?(1.1.1.1 - Recommended) [y/n]" -e -i "y" CHOICE
		if [ "$CHOICE" == "y" ]; then
			DNS="1.1.1.1,1.0.0.1"
		else
			DNS="8.8.8.8,8.8.4.4"
		fi
	fi
	
	if [ "$DIST" == "Ubuntu" ]; then
		apt update
		apt install software-properties-common -y
		add-apt-repository ppa:wireguard/wireguard -y
        apt update
        apt install wireguard qrencode iptables-persistent -y
	elif [ "$DIST" == "Debian" ]; then
		echo "deb http://deb.debian.org/debian/ unstable main" > /etc/apt/sources.list.d/unstable.list
        printf 'Package: *\nPin: release a=unstable\nPin-Priority: 90\n' > /etc/apt/preferences.d/limit-unstable
        apt update
        apt install wireguard qrencode iptables-persistent -y
	elif [ "$DIST" == "CentOS" ]; then
		curl -Lo /etc/yum.repos.d/wireguard.repo https://copr.fedorainfracloud.org/coprs/jdoss/wireguard/repo/epel-7/jdoss-wireguard-epel-7.repo
        yum install epel-release -y
        yum install wireguard-dkms qrencode wireguard-tools -y
	fi
	
	SERVER_PRIVKEY=$( wg genkey )
    SERVER_PUBKEY=$( echo $SERVER_PRIVKEY | wg pubkey )
    CLIENT_PRIVKEY=$( wg genkey )
    CLIENT_PUBKEY=$( echo $CLIENT_PRIVKEY | wg pubkey )
    CLIENT_ADDRESS="${PRIVATE_SUBNET::-4}3"
	
	mkdir -p /etc/wireguard
	touch $EVERYTHINGISOK
	chmod 600 $EVERYTHINGISOK
	
	echo "# $PRIVATE_SUBNET $IP:$PORT $SERVER_PUBKEY $DNS
[Interface]
Address = $GATEWAY_ADDRESS/$PRIVATE_SUBNET_MASK
ListenPort = $PORT
PrivateKey = $SERVER_PRIVKEY
SaveConfig = false" > $EVERYTHINGISOK

    echo "# client
[Peer]
PublicKey = $CLIENT_PUBKEY
AllowedIPs = $CLIENT_ADDRESS/32" >> $EVERYTHINGISOK

	echo "[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_ADDRESS/$PRIVATE_SUBNET_MASK
DNS = $DNS
[Peer]
PublicKey = $SERVER_PUBKEY
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $IP:$PORT
PersistentKeepalive = 25" > $HOME/wireguard-client.conf
	
	qrencode -t ansiutf8 -l L < $HOME/wireguard-client.conf
	
	echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    echo "net.ipv4.conf.all.forwarding=1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    sysctl -p

    if [ "$DISTRO" == "CentOS" ]; then
        firewall-cmd --zone=public --add-port=$PORT/udp
        firewall-cmd --zone=trusted --add-source=$PRIVATE_SUBNET
        firewall-cmd --permanent --zone=public --add-port=$PORT/udp
        firewall-cmd --permanent --zone=trusted --add-source=$PRIVATE_SUBNET
        firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s $PRIVATE_SUBNET ! -d $PRIVATE_SUBNET -j SNAT --to $IP
        firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s $PRIVATE_SUBNET ! -d $PRIVATE_SUBNET -j SNAT --to $IP
    else
        iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        iptables -A FORWARD -m conntrack --ctstate NEW -s $PRIVATE_SUBNET -m policy --pol none --dir in -j ACCEPT
        iptables -t nat -A POSTROUTING -s $PRIVATE_SUBNET -m policy --pol none --dir out -j MASQUERADE
        iptables -A INPUT -p udp --dport $PORT -j ACCEPT
        iptables-save > /etc/iptables/rules.v4
    fi

    systemctl enable wg-quick@wg0.service
    systemctl start wg-quick@wg0.service
	
	echo "Main Client configuration: $HOME/wireguard-client.conf"
	echo "Please reboot your server for stable connection. Congrats!!1!"
else
	NEW_CLIENT="$1"
	if [ "$NEW_CLIENT" = "" ]; then
		echo "Say 'The New Client's' Name!"
		read -p "New VPN Client's name(please use one word): " -e NEW_CLIENT
	fi
	
	CLIENT_PRIVKEY=$( wg genkey )
    CLIENT_PUBKEY=$( echo $CLIENT_PRIVKEY | wg pubkey )
    PRIVATE_SUBNET=$( head -n1 $EVERYTHINGISOK | awk '{print $2}')
    PRIVATE_SUBNET_MASK=$( echo $PRIVATE_SUBNET | cut -d "/" -f 2 )
    SERVER_ENDPOINT=$( head -n1 $EVERYTHINGISOK | awk '{print $3}')
    SERVER_PUBKEY=$( head -n1 $EVERYTHINGISOK | awk '{print $4}')
    DNS=$( head -n1 $EVERYTHINGISOK | awk '{print $5}')
    LASTIP=$( grep "/32" $EVERYTHINGISOK | tail -n1 | awk '{print $3}' | cut -d "/" -f 1 | cut -d "." -f 4 )
    CLIENT_ADDRESS="${PRIVATE_SUBNET::-4}$((LASTIP+1))"
    echo "# $NEW_CLIENT
[Peer]
PublicKey = $CLIENT_PUBKEY
AllowedIPs = $CLIENT_ADDRESS/32" >> $EVERYTHINGISOK

    echo "[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_ADDRESS/$PRIVATE_SUBNET_MASK
DNS = $DNS
[Peer]
PublicKey = $SERVER_PUBKEY
AllowedIPs = 0.0.0.0/0, ::/0 
Endpoint = $SERVER_ENDPOINT
PersistentKeepalive = 25" > $HOME/$NEW_CLIENT-wg0.conf
	
	qrencode -t ansiutf8 -l L < $HOME/$NEW_CLIENT-wg0.conf
	
	ip address | grep -q wg0 && wg set wg0 peer "$CLIENT_PUBKEY" allowed-ips "$CLIENT_ADDRESS/32"
    echo "New VPN Client added. Configuration file --> $HOME/$NEW_CLIENT-wg0.conf"
fi
