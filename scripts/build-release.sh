#!/bin/bash
# ora sürüm paketi: arşiv → .app → .dmg (+ mümkünse imza ve notarizasyon)
#
# Gömülecek bir çalışma zamanı yok (Python/Node/model dosyası yok), bu yüzden
# bu betik standart bir Xcode arşividir. Eski ora'nın Faz 9'da tıkandığı yer
# gömülü Python'du; burada o sorun yok.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/ora.xcarchive"
APP="$BUILD/ora.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Config/Info.plist" 2>/dev/null || echo 0.1.0)"
[[ "$VERSION" == *'$'* ]] && VERSION="$(grep -m1 MARKETING_VERSION "$ROOT/ora.xcodeproj/project.pbxproj" | sed 's/.*= *//; s/;//')"
DMG="$BUILD/ora-$VERSION.dmg"

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "▸ Arşivleniyor (Release)…"
xcodebuild -project "$ROOT/ora.xcodeproj" -scheme ora -configuration Release \
  -destination 'platform=macOS,arch=arm64' -archivePath "$ARCHIVE" archive \
  | grep -E "error:|warning: .*deprecated|ARCHIVE" || true

if [ ! -d "$ARCHIVE/Products/Applications/ora.app" ]; then
  echo "✗ Arşiv oluşmadı." >&2
  exit 1
fi
cp -R "$ARCHIVE/Products/Applications/ora.app" "$APP"

# --- İmza ---------------------------------------------------------------
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep 'Developer ID Application' | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"

if [ -n "$IDENTITY" ]; then
  echo "▸ İmzalanıyor: $IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$ROOT/Config/ora.entitlements" \
    --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "⚠︎ Developer ID kimliği bulunamadı — uygulama ad-hoc imzalı kalıyor."
  echo "  Bu .dmg başka bir Mac'te Gatekeeper tarafından engellenir."
  echo "  Gerçek dağıtım için Apple Developer Program üyeliği ve"
  echo "  'Developer ID Application' sertifikası gerekir."
fi

# --- DMG ----------------------------------------------------------------
echo "▸ .dmg hazırlanıyor…"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "ora" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

# --- Notarizasyon -------------------------------------------------------
# `xcrun notarytool store-credentials ora-notary` ile profil kurulmuş olmalı.
if [ -n "$IDENTITY" ] && xcrun notarytool history --keychain-profile ora-notary >/dev/null 2>&1; then
  echo "▸ Notarizasyona gönderiliyor…"
  xcrun notarytool submit "$DMG" --keychain-profile ora-notary --wait
  xcrun stapler staple "$DMG"
  echo "✓ Notarize edildi ve zımbalandı."
else
  echo "⚠︎ Notarizasyon atlandı (kimlik veya 'ora-notary' anahtarlık profili yok)."
fi

echo ""
echo "✓ Hazır: $DMG"
du -h "$DMG" | cut -f1 | sed 's/^/  boyut: /'
