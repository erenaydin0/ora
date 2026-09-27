import SwiftUI

/// Kilitliyken pencerenin tamamını örten ekran. Boş durumla aynı iskelet:
/// tek simge, iki satır, tek düğme.
struct LockScreen: View {

    let lock: AppLock

    var body: some View {
        VStack(spacing: 8) {
            OraLogo(height: 40)
                .padding(.bottom, 8)
                .accessibilityHidden(true)
            Text("ora kilitli")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.oraInk)
            Text("Toplantılarınızı görmek için Touch ID ya da Mac parolanızla "
                 + "kilidi açın.")
                .font(.system(size: 12))
                .foregroundStyle(Color.oraInkMuted)
                .multilineTextAlignment(.center)
            Button("Kilidi aç") { Task { await lock.unlock() } }
                .keyboardShortcut(.defaultAction)
                .disabled(lock.isAuthenticating)
                .padding(.top, 6)
            if let failure = lock.failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.oraRed)
            }
            Text("Kayıt ve toplantı algılama kilitliyken de çalışır.")
                .font(.system(size: 11))
                .foregroundStyle(Color.oraInkMuted)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(Color.oraPaper)
        // Kilit ekranı görünür görünmez doğrulama istenir; vazgeçilirse düğme durur.
        .task { await lock.unlock() }
    }
}

extension View {
    /// İçeriği kilitliyken örter. Altta kalan içerik tıklanamaz ve ekran
    /// okuyucuya da okunmaz — örtmek yalnızca görsel olmamalı.
    func lockable(_ lock: AppLock) -> some View {
        self
            .accessibilityHidden(lock.isLocked)
            .allowsHitTesting(!lock.isLocked)
            .overlay {
                if lock.isLocked {
                    LockScreen(lock: lock).transition(.opacity)
                }
            }
            .animation(OraStyle.transition, value: lock.isLocked)
    }
}
