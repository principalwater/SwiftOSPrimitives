#if os(macOS)
  import Darwin

  /// Descriptor-level checks that POSIX mode/uid validation alone cannot provide on macOS.
  public enum DarwinFileAuthority {
    public enum Failure: Error, Equatable, Sendable {
      case ownershipIgnored, extendedACL
      case system(Int32)
    }

    /// Requires enforced volume ownership and no extended ACL entries. The caller must
    /// separately validate file type, uid, permissions and links. Does not change permissions.
    public static func validate(_ descriptor: Int32) throws(Failure) {
      var filesystem = statfs()
      guard unsafe fstatfs(descriptor, &filesystem) == 0 else {
        throw .system(NativeMemorySystem.errorCode)
      }
      guard filesystem.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0 else {
        throw .ownershipIgnored
      }
      guard let access = unsafe acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
        // Darwin's descriptor ACL getter reports a missing ACL as ENOENT.
        guard NativeMemorySystem.errorCode == ENOENT else {
          throw .system(NativeMemorySystem.errorCode)
        }
        return
      }
      defer { _ = unsafe acl_free(UnsafeMutableRawPointer(access)) }
      guard unsafe acl_valid(access) == 0 else { throw .system(NativeMemorySystem.errorCode) }
      var entry: acl_entry_t?
      if unsafe acl_get_entry(access, ACL_FIRST_ENTRY.rawValue, &entry) == 0 {
        throw .extendedACL
      }
      guard NativeMemorySystem.errorCode == EINVAL else {
        throw .system(NativeMemorySystem.errorCode)
      }
    }
  }
#endif
