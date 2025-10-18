# MariaDB Galera Cluster for Frappe Apps

This deployment provides a highly available MariaDB Galera cluster for Frappe applications (ERPNext).

## Architecture

- **3-node Galera cluster** for high availability
- **Single-replica Ceph storage** to avoid triple data redundancy (Galera provides replication)
- **MariaDB Operator** for automated management
- **Daily backups** with 7-day retention
- **Prometheus metrics** and **Loki log monitoring**

## Components

1. **MariaDB Operator**: Manages the lifecycle of MariaDB instances
2. **MariaDB Galera Cluster**: 3-node cluster with automatic failover
3. **Backup CronJob**: Daily backups at 2 AM
4. **Monitoring**: Prometheus metrics and Loki alerting rules

## Storage

Uses `ceph-block-single-replica` storage class to optimize storage usage:
- Galera provides database-level replication (3x)
- Ceph single-replica avoids additional storage overhead
- Total effective redundancy: 3x (Galera only)

## Security

- Credentials stored in SOPS-encrypted secrets
- Root password and erpnext user password are auto-generated
- Network policies restrict access to frappe namespace

## Monitoring Alerts

- Cluster health status
- Connection errors
- Slow queries
- Replication lag
- Backup failures

## Usage

The cluster is automatically deployed when the frappe namespace is applied. ERPNext will use the local `mariadb-galera.frappe.svc.cluster.local` endpoint.