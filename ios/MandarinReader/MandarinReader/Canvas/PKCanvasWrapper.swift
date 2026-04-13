import SwiftUI
import PencilKit

/// SwiftUI wrapper around `PKCanvasView`. Binds the current `PKDrawing` back to the
/// parent so the view can clear the canvas or read it for recognition.
struct PKCanvasWrapper: UIViewRepresentable {

    @Binding var drawing: PKDrawing
    var onChange: ((PKDrawing) -> Void)? = nil

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = drawing
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 8)
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing {
            canvas.drawing = drawing
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PKCanvasWrapper
        init(parent: PKCanvasWrapper) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
            parent.onChange?(canvasView.drawing)
        }
    }
}

extension PKDrawing {
    /// Render the drawing on a white background at the given size, producing a
    /// UIImage suitable for `VNRecognizeTextRequest`.
    func rasterize(size: CGSize, scale: CGFloat = 2.0) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = scale
            format.opaque = true
            return format
        }())
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let inkImage = self.image(from: CGRect(origin: .zero, size: size), scale: scale)
            inkImage.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
