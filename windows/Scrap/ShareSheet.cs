using System.Runtime.InteropServices;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;

namespace Scrap;

public static class ShareSheet
{
    private static readonly Guid ManagerId = new("a5caee9b-8708-49d1-8d36-67d25a8da00c");
    private static DataTransferManager? manager;
    private static Uri? currentUrl;
    private static string currentTitle = "";
    private static readonly TypedEventHandler<DataTransferManager, DataRequestedEventArgs> Handler = OnDataRequested;
    [ComImport, Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDataTransferManagerInterop
    {
        nint GetForWindow(nint appWindow, ref Guid riid);
        void ShowShareUIForWindow(nint appWindow);
    }

    public static void Show(nint window, Uri url, string title)
    {
        currentUrl = url; currentTitle = title;
        var interop = DataTransferManager.As<IDataTransferManagerInterop>();
        if (manager == null)
        {
            var managerId = ManagerId;
            var pointer = interop.GetForWindow(window, ref managerId);
            manager = WinRT.MarshalInterface<DataTransferManager>.FromAbi(pointer);
            manager.DataRequested += Handler;
        }
        interop.ShowShareUIForWindow(window);
    }

    private static void OnDataRequested(DataTransferManager sender, DataRequestedEventArgs args)
    {
        if (currentUrl == null) return;
        args.Request.Data.Properties.Title = string.IsNullOrWhiteSpace(currentTitle) ? "Share track" : currentTitle;
        args.Request.Data.Properties.Description = "Last.fm track";
        args.Request.Data.SetWebLink(currentUrl);
    }
}
