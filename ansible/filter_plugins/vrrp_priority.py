
class FilterModule(object):
  def filters(self):
    return {'vrrp_priority': self.ip_last_octet}

  def ip_last_octet(self, ip_addr):
    return ip_addr.split('.')[-1]