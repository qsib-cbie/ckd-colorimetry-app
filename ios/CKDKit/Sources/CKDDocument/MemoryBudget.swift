import CKDImage
import Foundation

public enum MemoryBudget {
    public static let margin = 150 * 1_048_576
    public static let linearBytesPerPixel = 19
    public static let bayerBytesPerPixel = 13
    public static let heldImageBytesPerPixel = 4

    public static func required(pixels: Int, linear: Bool, holdsImage: Bool) -> Int {
        pixels * ((linear ? linearBytesPerPixel : bayerBytesPerPixel) + (holdsImage ? heldImageBytesPerPixel : 0)) + margin
    }

    public static func required(for original: URL, holdsImage: Bool) throws -> Int {
        let image = try QCamRawImport.inspect(url: original)
        return required(pixels: image.pixels, linear: image.linear, holdsImage: holdsImage)
    }

    public static func check(required: Int, available: Int) throws {
        guard available > 0, available < required else { return }
        let megabytes = { (bytes: Int) in (bytes + 1_048_575) / 1_048_576 }
        throw DocumentError("This image needs about \(megabytes(required)) MB of memory to process, and this iPad or iPhone has about \(megabytes(available)) MB free for the app right now. Close other apps and try again, or process the image on a Mac.")
    }
}
