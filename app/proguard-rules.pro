# Keep the JavaScript bridge interface — names are referenced from WebView JS by reflection.
-keepclassmembers class com.kotatko.sattracker.WebAppInterface {
    @android.webkit.JavascriptInterface <methods>;
}

# Google Play Billing
-keep class com.android.billingclient.** { *; }

# OkHttp / Okio
-dontwarn okhttp3.**
-dontwarn okio.**
