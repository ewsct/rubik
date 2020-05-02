#!/usr/bin/env python

from ansible.module_utils.basic import AnsibleModule
import platform

import stat
from os.path import isfile
from os import path
import json
import tempfile
import subprocess
import requests
from os import chmod, path

CFSSL_PATH = './cfssl'

def main():
  module = AnsibleModule(
    argument_spec=dict(
      state        = dict(default='present', choices=['present', 'absent', 'updated']),
      ca_certificate = dict(required=True),
      ca_key       = dict(required=True),
      certificate  = dict(required=True),
      key          = dict(required=True),
      common_name  = dict(required=False),
      hostnames    = dict(required=False, type=list, default=[])
    ),
    supports_check_mode=True
  )
    
  changed = False
  key = module.params['key']
  cert = module.params['certificate']
  ca_key = module.params['ca_key']
  ca_cert = module.params['ca_certificate']
  common_name = module.params['common_name']
  hostnames = module.params['hostnames']
  updated = True if module.params['state'] == 'updated' else False

  if not isfile(key) or not isfile(cert) or updated:
    changed = True
    output = make_certs(key, cert, ca_key, ca_cert, common_name=common_name, hostnames=hostnames)
  else:
    output = {
      'cert': read_from_file(cert),
      'key': read_from_file(key)
    }

  module.exit_json(
    changed=changed,
    key=output['key'],
    cert=output['cert']
  )
  
def read_from_file(filename):
  '''
  Read and return file content
  '''
  with open(filename, "rt") as f:
    return f.read()
  

def get_link(op_sys, arch):
  '''
  Get link to cfssl
  '''
  base_location = 'https://pkg.cfssl.org/R1.2'
  return f"{base_location}/cfssl_{op_sys}-{arch}"


def platform_info():
  '''
  Get OS type and architecture
  '''
  arch_types = {
    'x86_64': 'amd64'
  }
  arch = arch_types[platform.machine()]
  op_sys = platform.system().lower()
  return (op_sys, arch)


def make_certs(key_path, cert_path, ca_key, ca_cert, common_name=None, hostnames=[]):
  '''
  Generate and save certificate and key
  '''
  tmp_dir = tempfile.gettempdir()
  op_sys, arch = platform_info()
  
  if not isfile(CFSSL_PATH):
    link_url = get_link(op_sys, arch)
    download_cfssl(link_url, CFSSL_PATH)

  file_prefix = common_name if common_name else 'local'
  cfg_path = path.join(tmp_dir, f'{file_prefix}-csr.json')
  ca_cfg = path.join(tmp_dir, f'{file_prefix}-ca-config.json')
  profile = 'rubik'

  config_file(cfg_path, common_name)
  ca_config_file(ca_cfg, profile)
  extra_params = ['-hostname=' + ','.join(hostnames)]
  stdout = run_cfssl(ca_cert, ca_key, ca_cfg, profile, cfg_path, extra_params)

  output = json.loads(stdout)
  new_cert = output['cert']
  new_key = output['key']

  save_to_file(cert_path, new_cert)
  save_to_file(key_path, new_key)

  return output


def config_file(config_path, cn, names=[{}]):
  '''
  Make a config file
  '''
  cfg = {
    "CN": cn,
    "key": {
      "algo": "rsa",
      "size": 2048
    },
    "names": [
      {
        "C": "NL",
        "L": "Amsterdam",
        "O": "system:masters",
        "OU": "Kubernetes Rubik",
        "ST": "North Holland"
      }
    ]
  }
  save_to_file(config_path, json.dumps(cfg))


def ca_config_file(file_path, profile):
  '''
  Make a config file
  '''
  cfg = {
      "signing": {
        "default": {
          "expiry": "8760h"
        },
        "profiles": {
          profile: {
            "usages": ["signing", "key encipherment", "server auth", "client auth"],
            "expiry": "8760h"
          }
        }
      }
    }
  save_to_file(file_path, json.dumps(cfg))

def run_cfssl(ca_path, key_path, ca_cfg, ca_profile, cfg_path, extra_params=[]):
  '''
  Run cfssl tool to generate key pair
  '''
  cmd = [
    CFSSL_PATH,
    "gencert",
    f"-ca={ca_path}",
    f"-ca-key={key_path}",
    f"-config={ca_cfg}",
    f"-profile={ca_profile}"
  ] + extra_params + [cfg_path]
  process = subprocess.Popen(cmd,
                     stdout=subprocess.PIPE, 
                     stderr=subprocess.PIPE,
                     universal_newlines=True)
  stdout, stderr = process.communicate()
  return_code = process.poll()
  if return_code is not None and return_code != 0:
    raise Exception(f"{stderr}\nRunning command: {cmd}")
  return stdout

def save_to_file(filename, content):
  '''
  Save text to file
  '''
  with open(filename, "wt") as f:
    f.write(content)

def download_cfssl(url, dest_file):
  '''
  Download cfssl cli tool
  '''
  try:
    dest_cont = requests.get(url)
    with open(dest_file, 'wb') as dest_buf:
      dest_buf.write(dest_cont.content)
    chmod(dest_file, 0o755)
  except Exception as err:
    raise err

if __name__ == '__main__':
  main()
