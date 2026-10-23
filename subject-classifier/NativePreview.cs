using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Nailong {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public System.Drawing.Point point; }
    [ComImport, Guid("8895B1C6-B41F-4C1C-A562-0D564250836F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPreviewHandler {
        void SetWindow(IntPtr hwnd, ref RECT rect);
        void SetRect(ref RECT rect);
        void DoPreview(); void Unload(); void SetFocus(); void QueryFocus(out IntPtr hwnd);
        [PreserveSig] int TranslateAccelerator(ref MSG msg);
    }
    [ComImport, Guid("B824B49D-22AC-4161-AC8A-9916E8FA3F7F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IInitializeWithStream { void Initialize(IStream stream, uint mode); }
    [ComImport, Guid("B7D14566-0509-4CCE-A71F-0A554233BD9B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IInitializeWithFile { void Initialize([MarshalAs(UnmanagedType.LPWStr)] string file, uint mode); }
    [ComImport, Guid("7F73BE3F-FB79-493C-A6C7-7EE14E245841"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IInitializeWithItem { void Initialize([MarshalAs(UnmanagedType.IUnknown)] object item, uint mode); }
    public static class Native {
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wparam, string text);
        [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern IntPtr SetParent(IntPtr child, IntPtr parent);
        [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hwnd, int x, int y, int w, int h, bool redraw);
        [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd, int index);
        [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hwnd, int index, int value);
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
        [DllImport("shlwapi.dll", CharSet=CharSet.Unicode, PreserveSig=true)]
        internal static extern int SHCreateStreamOnFileEx(string name, uint mode, uint attributes, bool create, IStream template, out IStream stream);
        [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=true)]
        internal static extern int SHCreateItemFromParsingName(string name, IntPtr bindContext, ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object item);
        public static bool SameContent(Stream first, Stream second) {
            if (first.Length != second.Length) return false;
            first.Position=0; second.Position=0;
            byte[] a=new byte[65536], b=new byte[65536]; int n;
            while ((n=first.Read(a,0,a.Length))>0) {
                int offset=0;
                while (offset<n) { int m=second.Read(b,offset,n-offset); if(m==0)return false; offset+=m; }
                for(int i=0;i<n;i++) if(a[i]!=b[i])return false;
            }
            return true;
        }
    }
    public class PreviewPanel : Panel {
        object instance; IPreviewHandler handler; IStream stream; object item;
        public static string HandlerFor(string path) {
            string ext=Path.GetExtension(path), key="\\shellex\\{8895b1c6-b41f-4c1c-a562-0d564250836f}";
            string[] roots={ext, "SystemFileAssociations\\"+ext, Convert.ToString(Registry.GetValue("HKEY_CLASSES_ROOT\\"+ext,"",null))};
            foreach(string root in roots) {
                if(string.IsNullOrEmpty(root)) continue;
                string value=Convert.ToString(Registry.GetValue("HKEY_CLASSES_ROOT\\"+root+key,"",null));
                Guid id; if(Guid.TryParse(value,out id))return value;
            }
            return null;
        }
        public void OpenFile(string path) {
            CloseFile();
            string clsid=HandlerFor(path); if(clsid==null)throw new NotSupportedException("No registered preview handler");
            try {
                instance=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid(clsid)));
                handler=(IPreviewHandler)instance;
                var withStream=instance as IInitializeWithStream;
                var withFile=instance as IInitializeWithFile;
                var withItem=instance as IInitializeWithItem;
                if(withStream!=null) {
                    // STGM_READ | STGM_SHARE_DENY_NONE. The preview never writes the document.
                    Marshal.ThrowExceptionForHR(Native.SHCreateStreamOnFileEx(path,0x40,0,false,null,out stream));
                    withStream.Initialize(stream,0);
                } else if(withFile!=null) withFile.Initialize(path,0);
                else if(withItem!=null) {
                    Guid iid=new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
                    Marshal.ThrowExceptionForHR(Native.SHCreateItemFromParsingName(path,IntPtr.Zero,ref iid,out item));
                    withItem.Initialize(item,0);
                } else throw new NotSupportedException("Preview initialization is unavailable");
                RECT rect=new RECT{Right=ClientSize.Width,Bottom=ClientSize.Height};
                handler.SetWindow(Handle,ref rect); handler.DoPreview();
            } catch { CloseFile(); throw; }
        }
        protected override void OnResize(EventArgs e) {
            base.OnResize(e);
            if(handler!=null)try { RECT rect=new RECT{Right=ClientSize.Width,Bottom=ClientSize.Height}; handler.SetRect(ref rect); } catch { }
        }
        public void CloseFile() {
            if(handler!=null)try { handler.Unload(); } catch { }
            handler=null;
            if(instance!=null && Marshal.IsComObject(instance)) Marshal.FinalReleaseComObject(instance);
            instance=null;
            if(stream!=null && Marshal.IsComObject(stream)) Marshal.FinalReleaseComObject(stream);
            stream=null;
            if(item!=null && Marshal.IsComObject(item)) Marshal.FinalReleaseComObject(item);
            item=null;
        }
        protected override void Dispose(bool disposing) { if(disposing)CloseFile(); base.Dispose(disposing); }
    }
}

namespace Nailong {
    public class RoundSurface : System.Windows.Forms.Panel {
        public System.Drawing.Color Fill { get; set; }
        public System.Drawing.Color Stroke { get; set; }
        public int Radius { get; set; }
        public RoundSurface() {
            DoubleBuffered=true; Fill=System.Drawing.Color.White; Stroke=System.Drawing.Color.FromArgb(238,231,213); Radius=18;
            SetStyle(System.Windows.Forms.ControlStyles.SupportsTransparentBackColor,true);
            BackColor=System.Drawing.Color.Transparent;
        }
        protected override void OnPaint(System.Windows.Forms.PaintEventArgs e) {
            base.OnPaint(e); e.Graphics.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            float r=System.Math.Min(Radius,System.Math.Min(Width,Height)/2f-1),d=r*2;
            if(r<1)return;
            using(var p=new System.Drawing.Drawing2D.GraphicsPath()) {
                p.AddArc(0,0,d,d,180,90);p.AddArc(Width-d-1,0,d,d,270,90);
                p.AddArc(Width-d-1,Height-d-1,d,d,0,90);p.AddArc(0,Height-d-1,d,d,90,90);p.CloseFigure();
                using(var b=new System.Drawing.SolidBrush(Fill))e.Graphics.FillPath(b,p);
                using(var pen=new System.Drawing.Pen(Stroke))e.Graphics.DrawPath(pen,p);
            }
        }
    }
}

namespace Nailong {
    public class ThemeSearchButton : System.Windows.Forms.Button {
        bool hovered,pressed;
        public int Radius {get;set;}
        public ThemeSearchButton(){
            Radius=14;DoubleBuffered=true;
            SetStyle(System.Windows.Forms.ControlStyles.UserPaint|System.Windows.Forms.ControlStyles.AllPaintingInWmPaint|System.Windows.Forms.ControlStyles.OptimizedDoubleBuffer|System.Windows.Forms.ControlStyles.SupportsTransparentBackColor,true);
        }
        protected override void OnMouseEnter(System.EventArgs e){hovered=true;Invalidate();base.OnMouseEnter(e);}
        protected override void OnMouseLeave(System.EventArgs e){hovered=false;pressed=false;Invalidate();base.OnMouseLeave(e);}
        protected override void OnMouseDown(System.Windows.Forms.MouseEventArgs e){pressed=true;Invalidate();base.OnMouseDown(e);}
        protected override void OnMouseUp(System.Windows.Forms.MouseEventArgs e){pressed=false;Invalidate();base.OnMouseUp(e);}
        protected override void OnPaintBackground(System.Windows.Forms.PaintEventArgs e){
            var surface=Parent as RoundSurface;
            e.Graphics.Clear(surface!=null?surface.Fill:System.Drawing.Color.White);
        }
        protected override void OnPaint(System.Windows.Forms.PaintEventArgs e){
            e.Graphics.Clear(System.Drawing.Color.White);
            e.Graphics.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            float inset=1.0f, d=System.Math.Min(Radius*2,System.Math.Min(Width,Height)-4);
            using(var p=new System.Drawing.Drawing2D.GraphicsPath()){
                p.AddArc(inset,inset,d,d,180,90);p.AddArc(Width-d-inset-1,inset,d,d,270,90);
                p.AddArc(Width-d-inset-1,Height-d-inset-1,d,d,0,90);p.AddArc(inset,Height-d-inset-1,d,d,90,90);p.CloseFigure();
                var color=pressed?System.Drawing.Color.FromArgb(241,181,34):hovered?System.Drawing.Color.FromArgb(255,207,73):System.Drawing.Color.FromArgb(249,196,57);
                using(var brush=new System.Drawing.SolidBrush(color))e.Graphics.FillPath(brush,p);
                using(var pen=new System.Drawing.Pen(System.Drawing.Color.FromArgb(224,166,29),1.2f))e.Graphics.DrawPath(pen,p);
            }
            System.Windows.Forms.TextRenderer.DrawText(e.Graphics,Text,Font,ClientRectangle,ForeColor,System.Windows.Forms.TextFormatFlags.HorizontalCenter|System.Windows.Forms.TextFormatFlags.VerticalCenter|System.Windows.Forms.TextFormatFlags.NoPrefix);
        }
    }
}
