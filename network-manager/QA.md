重置libvirt 网络
sudo virsh net-destroy my-network && sudo virsh net-start my-network  && systemctl restart libvirtd

sudo netfilter-persistent save
sudo netfilter-persistent reload


sysctl -w net.ipv4.ip_forward=1 && echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf && sysctl -p 

如果允许虚机数据通过virbr0访问公网,别忘了在virbr0所在的防火墙配上postrouting规则，否则数据包转发不出去
-A LIBVIRT_PRT -s 172.16.30.0/24 ! -d 172.16.30.0/24 -j MASQUERADE 必选项
-A LIBVIRT_PRT -s 172.16.30.0/24 -d 224.0.0.0/24 -j RETURN   可选
-A LIBVIRT_PRT -s 172.16.30.0/24 -d 255.255.255.255/32 -j RETURN  可选	
-A LIBVIRT_PRT -s 172.16.30.0/24 ! -d 172.16.30.0/24 -p tcp -j MASQUERADE --to-ports 1024-65535	可选
-A LIBVIRT_PRT -s 172.16.30.0/24 ! -d 172.16.30.0/24 -p udp -j MASQUERADE --to-ports 1024-65535	可选


两个节点不在一个地址段，建vxlan
root@ZBook-G10:/home/ryan# ip route add 172.16.40.0/24 via 193.168.122.94 dev virbr1 
root@ZBook-G10:/home/ryan# ip route add 172.16.30.0/24 via 192.168.122.92 dev virbr0
另外注意的是虚机的默认网关都是由dhcp决定的，dhcp的网关地址要和节点地址一样，否则虚机访问不到网关，上不了网



1.问题总结
1.2个节点不在同一网段，建网的话，虚拟子网不能用同一个网段，因为如果一样，那路由没办法区分，比如我建一个路由 ip route add 172.16.30.0/24 via 192.168.122.91 dev virbr0, 再建一个基于另一个节点的路由
ip route add 172.16.30.0/24 via 193.168.122.94 dev virbr1， 这个建的时候会报错的，所以需要建成不同的子网来区分，这样路由也可以建起来，如ip route add 172.16.40.0/24 via 193.168.122.94 dev virbr1
这样就解决了
2.仔细检查节点地址和虚机的gateway地址是不是一样，虚机的gateway是有dhcp给的，如果地址不对网络路由也是会出问题的
3.防火墙ip4转发配好，nat转发也需要，尤其是由内网通过虚拟路由网卡访问外网时，这个规则是必须配的
4.跨zone的节点建立vxlan，每个zone内建立vlan,用vlan的bridge-host，替换掉原有vxlan的bridge-host，挂在vxlan veth-pair-host上即可
