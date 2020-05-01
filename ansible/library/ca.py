#!/usr/bin/env python

from ansible.module_utils.basic import *
from OpenSSL import crypto, SSL
from os.path import isfile
import random

DEFAULT_CA_KEY_SIZE = 4096

def main():
  module_args = dict(
    name=dict(type='str', required=True)
  )
  module = AnsibleModule(
    argument_spec=dict(
      #state        = dict(default='present', choices=['present', 'absent']),
      cert_file    = dict(required=True),
      key_file     = dict(required=True),
      config       = dict(type='dict', default={}),
      key_size     = dict(type='int', default=DEFAULT_CA_KEY_SIZE)
    ),
    supports_check_mode=True
  )
    
  changed = False
  key_file = module.params['key_file']
  cert_file = module.params['cert_file']
  config = module.params['config']
  response = {"key_file": key_file, "cert_file": cert_file}
  
  if module.check_mode:
    if not key_exists(key_file) or not cert_exists(cert_file):
      module.exit_json(changed=True, meta=response)

  if not key_exists(key_file):
    key = make_key()
    key_content = crypto.dump_privatekey(crypto.FILETYPE_PEM, key)
    save_to_file(key_file, key_content)
    crt = make_cert(config, key)
    save_to_file(cert_file, crt)
    changed = True
 
  if not cert_exists(cert_file):
    key = read_key(read_from_file(key_file))
    crt = make_cert(config, key)
    save_to_file(cert_file, crt)
    changed = True

  module.exit_json(
    changed=changed,
    key=read_from_file(key_file),
    cert=read_from_file(cert_file)
  )
  

def key_exists(filepath):
  if not isfile(filepath):
    return False
  try:
    _ = read_key(read_from_file(filepath))
  except Exception:
    return False
  return True

def cert_exists(filepath):
  if not isfile(filepath):
    return False
  try:
    _ = read_cert(read_from_file(filepath))
  except Exception:
    return False
  return True


def make_key():
  key = crypto.PKey()
  key.generate_key(crypto.TYPE_RSA, 4096)
  return key

def make_cert(settings, key):
  serialnumber = random.getrandbits(1024)
  cert = crypto.X509()
  cert.get_subject().C = settings.get('C', 'c')
  cert.get_subject().ST = settings.get('ST', 'st')
  cert.get_subject().L = settings.get('L', 'l')
  cert.get_subject().O = settings.get('O', 'o')
  cert.get_subject().OU = settings.get('OU', 'ou')
  cert.get_subject().CN = settings.get('CN', 'cn')
  cert.set_serial_number(serialnumber)
  cert.gmtime_adj_notBefore(0)
  cert.gmtime_adj_notAfter(31536000)
  cert.set_issuer(cert.get_subject())
  cert.set_pubkey(key)
  cert.sign(key, 'sha512')
  return crypto.dump_certificate(crypto.FILETYPE_PEM, cert)


def save_to_file(filename, content):
  with open(filename, "wt") as f:
    f.write(content.decode("utf-8"))

def read_from_file(filename):
  with open(filename, "rt") as f:
    return f.read()

def read_key(content):
  return crypto.load_privatekey(crypto.FILETYPE_PEM, content)

def read_cert(content):
  return crypto.load_certificate(crypto.FILETYPE_PEM, content)

if __name__ == '__main__':
  main()

