package dev.clipmesh.android

import android.content.ClipData
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import de.robv.android.xposed.IXposedHookLoadPackage
import de.robv.android.xposed.XC_MethodHook
import de.robv.android.xposed.XposedBridge
import de.robv.android.xposed.XposedHelpers
import de.robv.android.xposed.callbacks.XC_LoadPackage

/** No code executes inside arbitrary apps: select System Framework (android) only. */
class ClipboardHook: IXposedHookLoadPackage {
    override fun handleLoadPackage(param: XC_LoadPackage.LoadPackageParam) {
        if(param.packageName != "android" || param.processName != "android") return
        try {
            val service = XposedHelpers.findClass("com.android.server.clipboard.ClipboardService",param.classLoader)
            val thread = HandlerThread("ClipMeshBridge").apply { start() }
            val handler = Handler(thread.looper)
            var hooks = 0
            for(method in service.declaredMethods) {
                val types = method.parameterTypes
                // Hook the outer user clipboard update only. The inner overload has a private
                // Clipboard object first and also runs once for each related profile.
                if(method.name != "setPrimaryClipInternalLocked" || types.size < 2 || types[0] != ClipData::class.java || types[1] != Int::class.javaPrimitiveType) continue
                XposedBridge.hookMethod(method,object:XC_MethodHook() {
                    override fun afterHookedMethod(hook: MethodHookParam) {
                        if(hook.hasThrowable()) return
                        val clip = hook.args[0] as? ClipData ?: return
                        if(clip.itemCount == 0) return
                        val uid = hook.args[1] as? Int ?: return
                        if(uid / 100000 != 0) return // Physical owner profile only.
                        // Android 15 supports virtual-device clipboards. This app syncs the
                        // physical device's clipboard only, rather than crossing profiles/devices.
                        if(types.size > 2 && types[2] == Int::class.javaPrimitiveType && (hook.args[2] as? Int) != 0) return
                        val observed=android.os.SystemClock.elapsedRealtimeNanos()
                        val item = clip.getItemAt(0)
                        val uri = item.uri?.takeIf { it.scheme=="content" }
                        val text = item.text?.toString()
                        val image = uri!=null && clip.description.hasMimeType("image/*")
                        if(!image && text==null) return
                        if(!image && text!!.contains("clipmesh://join#")) return
                        val bytes = if(image) null else text!!.toByteArray(Charsets.UTF_8)
                        if(bytes!=null && bytes.size>MAX_TEXT_BYTES) return
                        val serviceObject = hook.thisObject
                        val context = try { XposedHelpers.getObjectField(serviceObject,"mContext") as? Context } catch (_:Throwable) { null } ?: return
                        // Binder identity on this worker is system UID, never the copying app.
                        // A pipe avoids the Binder transaction size limit for long text.
                        synchronized(handler) {
                          handler.removeCallbacksAndMessages(null)
                          handler.post {
                            var pipe: Array<ParcelFileDescriptor>? = null
                            try {
                                if(image) {
                                    val enabled=context.contentResolver.call(Uri.parse("content://dev.clipmesh.android.bridge"),"capture_enabled",null,Bundle().apply { putInt("user_id",uid/100000) })?.getBoolean("enabled")==true
                                    if(!enabled) return@post
                                    // Reuse ClipboardService's existing clipboard-scoped URI owner.
                                    // The grant is read-only, to ClipMesh alone, revoked by Android
                                    // when this clipboard is replaced. No provider is made public.
                                    XposedHelpers.callMethod(serviceObject,"grantUriPermission",uri,uid,"dev.clipmesh.android",uid/100000)
                                    val extras=Bundle().apply { putInt("user_id",uid/100000); putLong("observed_ns",observed); putString("mime","image/*"); putParcelable("image_uri",uri) }
                                    context.contentResolver.call(Uri.parse("content://dev.clipmesh.android.bridge"),"capture",null,extras)
                                    return@post
                                }
                                val localPipe = ParcelFileDescriptor.createPipe()
                                pipe = localPipe
                                val extras = Bundle().apply { putInt("user_id",uid / 100000); putLong("observed_ns",observed); putString("mime",if(image) "image/*" else "text/plain"); putParcelable("stream",localPipe[0]) }
                                context.contentResolver.call(Uri.parse("content://dev.clipmesh.android.bridge"),"capture",null,extras)
                                localPipe[0].close()
                                ParcelFileDescriptor.AutoCloseOutputStream(localPipe[1]).use { it.write(bytes!!) }
                            } catch (_:Throwable) {
                                // Module/app can be absent, stopped, locked, or upgrading. Never
                                // interrupt the system clipboard and never log clipboard text.
                                pipe?.forEach { try { it.close() } catch (_:Throwable) {} }
                                if(image) try {
                                    context.contentResolver.call(Uri.parse("content://dev.clipmesh.android.bridge"),"capture_status","image_grant_failed",Bundle().apply { putInt("user_id",uid/100000) })
                                } catch (_:Throwable) {}
                            }
                          }
                        }
                    }
                })
                hooks++
            }
            XposedBridge.log("ClipMesh: clipboard bridge hooks=$hooks (no clipboard contents logged)")
        } catch (_:Throwable) { XposedBridge.log("ClipMesh: unsupported ClipboardService layout; bridge disabled") }
    }
}
