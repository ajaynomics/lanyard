# A mistyped APP__NATIVE_SIGN_IN_SCHEME fails the boot, not a person's sign-in.
Rails.application.config.after_initialize { NativeSignIn.scheme }
