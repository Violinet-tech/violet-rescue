# Driver packs

Put extracted drivers (folders that contain `.inf` files) here before building the media:

| Folder | What goes in it | Where to get it |
|---|---|---|
| `nvidia/` | NVIDIA display driver, extracted (the `Display.Driver` folder from the installer, opened with 7-Zip) | nvidia.com driver download |
| `realtek/` | Realtek LAN driver (`.inf`, `.sys`, `.cat`). `net-up` loads these so wired Ethernet works in the rescue environment | Realtek or the motherboard maker's support page |
| `amd-chipset/` | AMD chipset drivers, extracted | amd.com |

The **Install drivers** button (`add-drivers`) installs a folder into the offline Windows.
The **Remove NVIDIA display** and **Remove driver** buttons take them out again.

NVIDIA's and Realtek's licences do not allow us to redistribute their drivers in a
release. Fill these folders for your own media only; a released build downloads them
on the user's machine instead.
