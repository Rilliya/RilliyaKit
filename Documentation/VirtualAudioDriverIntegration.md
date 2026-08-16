# Integrating the Virtual Audio Driver

`RilliyaVirtualAudio` separates endpoint management from privileged driver
installation. The Swift package provides validated value types and a store for
the Rilliya driver. It does not install, sign, or load privileged code.

The clean-room Audio Server plug-in source is published with the
[Rilliya application](https://github.com/Rilliya/Rilliya/tree/main/Driver) under
the Apache License 2.0. It uses Apple's public Core Audio plug-in interfaces and
has no third-party runtime dependency.

## Manage endpoints

The default store locates the installed Rilliya driver and updates its endpoint
catalog through Core Audio. Each mutation reads the latest catalog first, so a
stale process cannot silently overwrite a newer revision.

```swift
import RilliyaVirtualAudio

let store = VirtualAudioEndpointStore()

guard try await store.availability() == .available else {
  // Offer the host application's signed installer.
  return
}

let endpoint = try await store.create(
  VirtualAudioEndpointConfiguration(
    name: "Broadcast Mix",
    direction: .input,
    format: .stereo48kHz
  )
)

print(endpoint.deviceUIDs.visible)
```

An input endpoint exposes host-produced audio to other applications. An output
endpoint accepts audio from other applications for the host to consume. Every
endpoint also has a hidden bridge device used by the host. Persist the endpoint
ID in workflows and derive current device UIDs from the returned endpoint; do
not persist transient Core Audio object IDs.

Catalog replacement is a control-plane operation. The driver rejects it while
any published device is running, so a host should pause dependent workflows
before changing an endpoint's direction or format. Store errors preserve the
failed operation and Core Audio status where applicable.

## Ship the driver

A distributing application is responsible for the privileged boundary:

1. Build the `.driver` bundle for every supported architecture and combine the
   executable into one Universal bundle.
2. Sign the bundle with that distributor's own **Developer ID Application**
   identity and the hardened runtime.
3. Place it at
   `/Library/Audio/Plug-Ins/HAL/RilliyaVirtualAudioDriver.driver` in a component
   package signed with the distributor's own **Developer ID Installer**
   identity.
4. Notarize and staple the installer package before distribution.
5. Explain that installation requires administrator authorization and a restart
   before Core Audio loads the plug-in.

The Developer ID Installer certificate is not tied to an application bundle ID.
The driver bundle itself has a stable bundle identifier, and the package has a
separate stable package identifier. Consumers never need Rilliya's signing
certificates: a distributor signs its build with identities from its own Apple
Developer account.

Rilliya's release scripts are a complete, inspectable example of Universal
assembly, fixed-path packaging, signing, and notarization. They intentionally do
not kill or restart Core Audio during installation.

## Security boundary

Treat endpoint names and catalogs as untrusted persisted input. Construct them
through `VirtualAudioEndpointConfiguration` and keep the built-in endpoint and
catalog limits. Do not invoke private Core Audio APIs, write directly into the
driver's storage, or bypass revision checks. A host should expose installation
as an explicit user action rather than silently requesting administrator
authorization.
