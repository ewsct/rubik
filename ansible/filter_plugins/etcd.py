
class FilterModule(object):
  def filters(self):
    return {
      'etcd_initial_cluster': self.etcd_init_cluster,
      'etcd_cluster': self.etcd_cluster
      }

  def etcd_init_cluster(self, ip_addrs):
    full_addrs = [ f'master-{index}=https://{ip}:2380' for index, ip in enumerate(ip_addrs) ]
    return ','.join(full_addrs)

  def etcd_cluster(self, ip_addrs):
    full_addrs = [ f'https://{ip}:2379' for ip in ip_addrs ]
    return ','.join(full_addrs)