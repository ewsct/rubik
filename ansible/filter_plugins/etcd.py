
class FilterModule(object):
  def filters(self):
    return {'etcd_initial_cluster': self.ip_last_octet}

  def ip_last_octet(self, ip_addrs):
    full_addrs = [ f'master-{index}=https://{ip}:2380' for index, ip in enumerate(ip_addrs) ]
    return ','.join(full_addrs)