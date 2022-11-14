#!/bin/bash

# Update repositories
export DEBIAN_FRONTEND=noninteractive
apt-get update

# Disable built-in firewall. Management will be done direct with iptables
ufw disable

# Install tools
apt-get install net-tools -y

# Install support for persistency to iptables
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
apt-get install iptables-persistent -y

# Add kernal modules to support vrfs
apt-get install linux-modules-extra-$(uname -r) -y

# Enable IPv4 forwarding
sed -r -i 's/#{1,}?net.ipv4.ip_forward ?= ?(0|1)/net.ipv4.ip_forward = 1/g' /etc/sysctl.conf

# Enable vrf support in network stack
sysctl -p | grep -i "net.ipv4.tcp_l3"
if [ $? -eq 1 ]
then
    echo "net.ipv4.tcp_l3mdev_accept = 1" >> /etc/sysctl.conf
    echo "net.ipv4.udp_l3mdev_accept = 1" >> /etc/sysctl.conf
    sysctl -p
fi

# Configure routing
ls -l /etc/systemd/system/routingconfig.service
if [ $? -eq 2 ]
then
    cat << EOF |
[Unit]
Description=Configure vrf and routing for machine

[Service]
Type=oneshot
RemainAfterExit=yes

ExecStart=/bin/bash -c "ip link add vrflan type vrf table 10"
ExecStart=/bin/bash -c "ip link set dev vrflan up"
ExecStart=/bin/bash -c "ip link set dev eth1 master vrflan"
ExecStart=/bin/bash -c "sleep 5"
ExecStart=/bin/bash -c "ip route add table 10 0.0.0.0/0 via $4"
ExecStart=/bin/bash -c "ip route add table 10 168.63.129.16 via $3"
ExecStart=/bin/bash -c "ip route add table 10 $1 via $3"
ExecStart=/bin/bash -c "ip route add table 10 $2 via $3"
ExecStart=/bin/bash -c "ip route add table 10 unreachable default metric 4278198272"
ExecStart=/bin/bash -c "ip route add $1 dev vrflan"
ExecStart=/bin/bash -c "ip route add $2 dev vrflan"

[Install]
WantedBy=multi-user.target
EOF
    awk '{print}' > /etc/systemd/system/routingconfig.service

    systemctl daemon-reload
    systemctl start routingconfig.service
    systemctl enable routingconfig.service
fi

#   Configure iptables
# # Configure support for NAT for Internet-bound traffic
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# # Allow and forward traffic out of vrf (LAN) to eth0 (Internet)
iptables -A FORWARD -i eth0 -o vrflan -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i vrflan -o eth0 -j ACCEPT

# # Allow and forward traffic between eth1 (LAN) and vrf (LAN)
iptables -A FORWARD -i eth1 -o vrflan -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i vrflan -o eth1 -j ACCEPT

# # Log traffic that is dropped
iptables -A FORWARD -i eth0 -j LOG --log-prefix "Dropping FORWARD traffic on eth0: "
iptables -A FORWARD -i eth0 -j DROP

# # Allow SSH traffic in eth0 and eth1
iptables -A INPUT -p tcp --dport ssh -j LOG --log-prefix "Allowing SSH traffic: "
iptables -A INPUT -p tcp --dport ssh -j ACCEPT

# # Allow return traffic across all interfaces
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# # Drop all other traffic sent directly to routers
iptables -A INPUT -i eth0 -j LOG --log-prefix "Dropping INPUT traffic on eth0: "
iptables -A INPUT -i eth0 -j DROP

# # Allow return traffic from sessions that interact with processes running on machine (such as ssh)
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# # Make the iptable rules persistent
sudo -i
sudo iptables-save > /etc/iptables/rules.v4
exit
