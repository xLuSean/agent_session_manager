import Foundation

enum NativeDeletePreviewSheetLayout {
    static func size(visibleScreenSize: CGSize) -> CGSize {
        CGSize(
            width: min(760, max(1, visibleScreenSize.width - 80)),
            height: min(820, max(1, visibleScreenSize.height - 120))
        )
    }
}

enum NativeDeleteReportSheetLayout {
    // Leave room for the parent window's chrome and keep the footer outside
    // the scrolling report. Long messages and large batches must not grow it.
    static func size(visibleScreenSize: CGSize) -> CGSize {
        CGSize(
            width: min(1_000, max(1, visibleScreenSize.width - 80)),
            height: min(720, max(1, visibleScreenSize.height - 120))
        )
    }

    static func tableHeight(itemCount: Int) -> CGFloat {
        min(300, 60 + CGFloat(min(6, max(0, itemCount))) * 40)
    }
}
