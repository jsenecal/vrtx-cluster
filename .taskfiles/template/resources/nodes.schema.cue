package config

import (
	"net"
	"list"
)

#Config: {
	nodes: [...#Node]
	_nodes_check: {
		name: list.UniqueItems() & [for item in nodes {item.name}]
		address: list.UniqueItems() & [for item in nodes {item.address}]
	}
}

#Node: {
	name:          =~"^[a-z0-9][a-z0-9\\-]{0,61}[a-z0-9]$|^[a-z0-9]$" & !="global" & !="controller" & !="worker"
	address:       net.IPv4
	controller:    bool
	disk:          string
	schematic_id:  =~"^[a-z0-9]{64}$"
	mtu?:          >=1450 & <=9000
	secureboot?:   bool
	encrypt_disk?: bool
	
	// Networking configuration (either bond or mac_addr)
	bond?: bool
	mac_addr?: =~"^([0-9a-f]{2}[:]){5}([0-9a-f]{2})$"
	
	// Bond configuration (optional)
	bond_interfaces?: [...=~"^([0-9a-f]{2}[:]){5}([0-9a-f]{2})$|^([0-9a-f]{2}[:]){1,5}\\*$"]
	bond_use_selectors?: bool
	bond_mode?: string
	bond_lacp_rate?: string
	bond_xmit_hash_policy?: string
	bond_miimon?: int
}

#Config
