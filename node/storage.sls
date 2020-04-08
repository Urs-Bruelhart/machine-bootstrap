{% from "machine-bootstrap/node/defaults.jinja" import settings %}

include:
  - .hostname
  - .accounts

{% for fs in settings.storage.filesystem.zfs|d([]) %}
zfs_fs_present_{{ fs.name }}:
  zfs.filesystem_present:
    - name: {{ fs.name }}
{%- for name,value in fs.items() %}
{%- if name != 'name' %}
    - {{ name }}: {{ value }}
{%- endif %}
{%- endfor %}

{% for fs in settings.storage.filesystem.lvm|d([]) %}
lvm_fs_present_{{ fs.name }}:
  lvm.lv_present:
    - name: {{ fs.name }}
{%- for name,value in fs.items() %}
{%- if name != 'name' %}
    - {{ name }}: {{ value }}
{%- endif %}
{%- endfor %}

{% for m in settings.storage.mount|d([]) %}
mounted_fs_{{ m.name }}:
  file.directory:
    - name: {{ m.name }}
    - makedirs: true
  mount.mounted:
    - name: {{ m.name }}
{%- for name,value in m.items() %}
{%- if name != 'name' %}
    - {{ name }}: {{ value }}
{%- endif %}
{%- endfor %}

{% for d in settings.storage.directory|d([]) %}
directory_{{ d.name }}:
  file.directory:
    - name: {{ d.name }}
    - makedirs: true
{%- for name,value in d.items() %}
{%- if name != 'name' %}
    - {{ name }}: {{ value }}
{%- endif %}
{%- endfor %}
