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
	disk?:          string  // Can be device path like "/dev/sda" or storage selector like "serial:123456"
	disk_by_wwid?:   string  // Disk selection by WWID (World Wide Identifier)
	schematic_id:  =~"^[a-z0-9]{64}$"
	mtu?:          >=1450 & <=9000
	secureboot?:   bool
	encrypt_disk?: bool
	
	// Networking configuration (either bond or mac_addr)
	bond?: bool
	mac_addr?: =~"^([0-9a-f]{2}[:]){5}([0-9a-f]{2})$"
	
	// Bond configuration (optional)
	bond_interfaces?: [...=~"^([0-9a-f]{2}[:]){5}([0-9a-f]{2})$|^([0-9a-f]{2}[:]){1,5}\\*$"]  // MAC addresses for bonding (permanent addresses recommended)
	bond_interface_names?: [...string]  // Interface names for bonding (like "eno1", "eno2")
	bond_bus_paths?: [...string]  // PCI bus paths (like "00:*" or "00:01.0")
	bond_pci_ids?: [...string]  // PCI vendor:product IDs (like "8086:*" or "8086:1533")
	bond_drivers?: [...string]  // Network driver names (like "igb" or "virtio_net")
	bond_combined_selectors?: [...{
		hardwareAddr?: string
		permanentAddr?: string
		busPath?: string
		pciID?: string
		driver?: string
	}]  // Combined selectors with multiple criteria
	bond_use_selectors?: bool   // Whether to use deviceSelectors instead of direct interface list
	bond_mode?: string
	bond_lacp_rate?: string
	bond_xmit_hash_policy?: string
	bond_miimon?: int
}

#Config
