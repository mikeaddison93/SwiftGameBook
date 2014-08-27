//
//  ImageTools.swift
//
//  Created by Paul Nettle on 8/1/14.
//  Copyright (c) 2014 backstopmedia. All rights reserved.
//

import SpriteKit

// Force re-vectorization of these sprite names (ignoring any existing cache files)
//
// Example: [ "cloud1", "platform1" ]
let forceRevectorization: [String] = []
let disableCache = false

// Constants
let LeftNeighborMask = 0x01
let RightNeighborMask = 0x02
let TopNeighborMask = 0x04
let BottomNeighborMask = 0x08
let SelfEdgeMask = 0x10
let VisitedMask = 0x20

let AllNeighborMasks = LeftNeighborMask | RightNeighborMask | TopNeighborMask | BottomNeighborMask

// Constants
let BlueComponentOffset = 0
let GreenComponentOffset = 1
let RedComponentOffset = 2
let AlphaComponentOffset = 3
let BytesPerPixel = 4

// While tracing edges, we use this tolerance to determine when to break the segment into multiple pieces
// Larger number means more error allowed, so there will be fewer segments making up the path
let EdgeAngleTolerance: CGFloat = 2
let AlphaThreshold: UInt8 = 128
let ColorThreshold: Int32 = 50

var vectorizedShapes = [String :[[CGPoint]]]()

class WritableCoordinate {
    var x: CGFloat = 0
    var y: CGFloat = 0
    
    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }
}

class ImageTools {
	
	// Find a "vertex neighbor" that is an "edge pixel"
	class func neighboringEdgePixel(imgMap: [UInt8], stride: Int, x: Int, y: Int) -> Point2D? {
		// These are our neighbors
		//
		// a b c
		// d   e
		// f g h
		
		let idx = y * stride + x
		let a = Int(imgMap[idx - 1 - stride])
		let b = Int(imgMap[idx     - stride])
		let c = Int(imgMap[idx + 1 - stride])
		
		let d = Int(imgMap[idx - 1])
		let e = Int(imgMap[idx + 1])
		
		let f = Int(imgMap[idx - 1 + stride])
		let g = Int(imgMap[idx     + stride])
		let h = Int(imgMap[idx + 1 + stride])
		
		if (e & SelfEdgeMask) != 0 && (e & AllNeighborMasks) != 0 && (e & AllNeighborMasks) != AllNeighborMasks && (e & VisitedMask) == 0 {
			return Point2D(x: x+1, y: y)
		}
		if (h & SelfEdgeMask) != 0 && (h & AllNeighborMasks) != 0 && (h & AllNeighborMasks) != AllNeighborMasks && (h & VisitedMask) == 0 {
			return Point2D(x: x+1, y: y+1)
		}
		if (g & SelfEdgeMask) != 0 && (g & AllNeighborMasks) != 0 && (g & AllNeighborMasks) != AllNeighborMasks && (g & VisitedMask) == 0 {
			return Point2D(x: x, y: y+1)
		}
		if (f & SelfEdgeMask) != 0 && (f & AllNeighborMasks) != 0 && (f & AllNeighborMasks) != AllNeighborMasks && (f & VisitedMask) == 0 {
			return Point2D(x: x-1, y: y+1)
		}
		if (d & SelfEdgeMask) != 0 && (d & AllNeighborMasks) != 0 && (d & AllNeighborMasks) != AllNeighborMasks && (d & VisitedMask) == 0 {
			return Point2D(x: x-1, y: y)
		}
		if (a & SelfEdgeMask) != 0 && (a & AllNeighborMasks) != 0 && (a & AllNeighborMasks) != AllNeighborMasks && (a & VisitedMask) == 0 {
			return Point2D(x: x-1, y: y-1)
		}
		if (b & SelfEdgeMask) != 0 && (b & AllNeighborMasks) != 0 && (b & AllNeighborMasks) != AllNeighborMasks && (b & VisitedMask) == 0 {
			return Point2D(x: x, y: y-1)
		}
		if (c & SelfEdgeMask) != 0 && (c & AllNeighborMasks) != 0 && (c & AllNeighborMasks) != AllNeighborMasks && (c & VisitedMask) == 0 {
			return Point2D(x: x+1, y: y-1)
		}
		
		return nil
	}

	// Returns an array of bytes containing the RGBA pixel data.
	// Each pixel is 4 bytes with one byte per color component.
	// Color components appear in [r, g, b, a] order
	// Each component is 8 bits (0-255)
	class func getBitmapBitsForImage(image: UIImage) -> [UInt8] {
		// Our image width/height. We use CGImageGet* to get the actual pixel dimensions)
		let widthPix = Int(CGImageGetWidth(image.CGImage))
		let heightPix = Int(CGImageGetHeight(image.CGImage))
		
		// Stride is the number of bytes in a single scanline.
		//
		// One of the purposes of stride is to account for padding to specific byte boundaries, but here, it's just the
		// width multiplied by the number of bytes per pixel.
		let stride = widthPix * BytesPerPixel
		
		// Here is our bitmap array
		var data = [UInt8](count: heightPix * stride, repeatedValue: UInt8(0))
		let colorSpace = CGColorSpaceCreateDeviceRGB()
		let bitmapInfo = CGBitmapInfo.fromRaw(CGImageAlphaInfo.PremultipliedLast.toRaw() | CGBitmapInfo.ByteOrderDefault.toRaw())
		let contextRef = CGBitmapContextCreate(&data, UInt(widthPix), UInt(heightPix), 8, UInt(stride), colorSpace, bitmapInfo!);
		let cgImage = image.CGImage;
		let rect = CGRect(x: 0, y: 0, width: CGFloat(widthPix), height: CGFloat(heightPix));
		CGContextDrawImage(contextRef, rect, cgImage);

		return data
	}

	// Build a neighbor map
	class func getImageMap(image: [UInt8], widthPix: Int, heightPix: Int) -> [UInt8] {
		// We'll store our image map here
		var imgMap = [UInt8](count: widthPix * heightPix, repeatedValue: 0)
		
		// We're going to be comparing the distance of pixel colors in the RGB color space with a thredhold value.
		// Distance calculations require square roots. To avoid the square root, we'll just square our threshold.
		let colorThresholdSquared = ColorThreshold * ColorThreshold
		
		// Scan the image and build our map
		//
		// Note that this process requires comparing pixels against their neighbors, edge pixels don't have neighbors, we
		// limit our range to [1 ..< n-1] for X and Y.
		for y in 1 ..< heightPix-1 {
			var lineIndex = y * widthPix
			for x in 1 ..< widthPix-1 {
				var pixIndex = lineIndex + x
				
				// If our alpha doesn't meet our threshold, then we're outside of any object in the image
				let a = image[pixIndex * BytesPerPixel + AlphaComponentOffset]
				if a < AlphaThreshold {
					continue
				}
				
				// Get our RGB component so we can compare it against each of our neighbors
				let r = Int32(image[pixIndex * BytesPerPixel + RedComponentOffset])
				let g = Int32(image[pixIndex * BytesPerPixel + GreenComponentOffset])
				let b = Int32(image[pixIndex * BytesPerPixel + BlueComponentOffset])

				// Check our neighbors for an edge condition (either no alpha for an alpha edge or
				// a large enough difference in the color)
				var onEdge = false
				
				for offset in [-1, 1, -widthPix, widthPix, -widthPix-1, -widthPix+1, widthPix-1, widthPix-1] {
					let neighborIndex = (pixIndex + offset) * BytesPerPixel
					let na = image[neighborIndex + AlphaComponentOffset]
					if na < AlphaThreshold {
						onEdge = true
						break
					}
					
					// Extract the color of this neighbor
					let nr = Int32(image[neighborIndex + RedComponentOffset])
					let ng = Int32(image[neighborIndex + GreenComponentOffset])
					let nb = Int32(image[neighborIndex + BlueComponentOffset])
					
					// Calculate the color difference between the neighbor's RGB and the current pixel's RGB
					// using the 3D distance equation:
					let dr = nr - r
					let dg = ng - g
					let db = nb - b
					let distSquared = dr * dr + dg * dg + db * db
					if distSquared > colorThresholdSquared {
						onEdge = true
						break
					}
				}
				
				if onEdge {
					imgMap[pixIndex] |= UInt8(SelfEdgeMask)
					imgMap[pixIndex - 1] |= UInt8(RightNeighborMask)
					imgMap[pixIndex + 1] |= UInt8(LeftNeighborMask)
					imgMap[pixIndex - widthPix] |= UInt8(BottomNeighborMask)
					imgMap[pixIndex + widthPix] |= UInt8(TopNeighborMask)
				}
			}
		}
		
		return imgMap
	}

	// Definitions:
	//
	// "Edge neighbor"   = Neighbor that shares an edge. These are pixel neighbors in the four primary directions
	//                     (up, down, left, right)
	// "Edge pixel"      = Any pixel that has an empty "Edge neighbor"
	// "Vertex neighbor" = Neighbor that shares a vertex. These are any of the eight neighbors (including corner
	//                     neighbors)
	class func vectorizeImage(name: String? = nil, var image: UIImage? = nil) -> ([[CGPoint]])? {
		if name != .None {
			// Get it from the local cache in memory
			if let pathArray = vectorizedShapes[name!] {
				return pathArray
			}
			
			// We're going to check to see if we need to bother updating our vectorized path file.
			//
			// Our default is set to the disableCache flag (if we're disabling the cache, then we'll assume
			// that the file is automatically out-of-date.)
			var outOfDate = disableCache

			// If we haven't yet determined if it's out of date, check the actual timestamps now
			let fileManager = NSFileManager()
			let pathFilename = getPathArrayFilename(name!)
			if !outOfDate {
				if let pathFileCreationDate = fileManager.attributesOfItemAtPath(pathFilename, error: nil)?["NSFileModificationDate"] as? NSDate {
					let assetFilename = "\(NSBundle.mainBundle().bundlePath)/Assets.car"
					if let imageFolderCreationDate = fileManager.attributesOfItemAtPath(assetFilename, error: nil)?["NSFileModificationDate"] as? NSDate {
						// Is our path file older than the asset file?
						if imageFolderCreationDate.compare(pathFileCreationDate) == NSComparisonResult.OrderedDescending {
							// Our path file is out of date
							NSLog("Image determined to be out of date: \(name!)")
							outOfDate = true
						}
					}
				}
			}
			
			// If it's out of date, delete the vector path file so it can be regenerated
			if outOfDate {
				fileManager.removeItemAtPath(pathFilename, error: nil)
			}
			// Try to load the path file if it exists
			else if let pathArray = readPathArray(name!) {
				vectorizedShapes[name!] = pathArray
				return pathArray
			}
			
			// We'll need to generate one from the named image, so load the image if it wasn't provided
			if image == .None {
				image = UIImage(named: name)
			}
		}

		// If we don't have an image at this point, we can't continue
		if image == .None {
			return nil
		}
		
		let widthPix = Int(CGImageGetWidth(image!.CGImage))
		let heightPix = Int(CGImageGetHeight(image!.CGImage))
		var imgData = getBitmapBitsForImage(image!)
		var imgMap = getImageMap(imgData, widthPix: widthPix, heightPix: heightPix)
		var totalPoints = 1
		var pathArray: [[CGPoint]] = []
		
		while true {
			var pixCur: Point2D!
			
			pixSearchLoop:
			for y in 0 ..< heightPix {
				var lineIndex = y * widthPix
				for x in 0 ..< widthPix {
					var pix = Int(imgMap[lineIndex + x])
					
					if (pix & SelfEdgeMask) != 0 && (pix & AllNeighborMasks) != 0 && (pix & AllNeighborMasks) != AllNeighborMasks && (pix & VisitedMask) == 0 {
						// Keep track of the first one we find, this is where we'll start tracing the image
						if pixCur == nil {
							pixCur = Point2D(x: x, y: y)
							break pixSearchLoop
						}
					}
				}
			}
			
			// if we didn't find an edge pixel, there's no alpha in the entire image that's above our threshold
			if pixCur == nil {
				break
			}
			
			// Set this pixel as visited
			imgMap[pixCur.y * widthPix + pixCur.x] |= UInt8(VisitedMask)
			
			// We'll use this vector as we trace around the edge to keep track of how much we bend around corners
			// so we'll know when it's time to create a new segment
			var vectorStart = pixCur.toCGVector()
			var vectorDir: CGVector?
			var totalError: CGFloat = 0
			
			// Let's build a path around the perimeter of our image
			//
			// We start with our first pixel point
			var path: [CGPoint] = [pixCur.toCGPoint()]
			totalPoints += 1
			
			while true {
				// Find the next pixel on the perimeter
				var pixPrev = pixCur
				pixCur = neighboringEdgePixel(imgMap, stride: widthPix, x: pixCur.x, y: pixCur.y)
				
				// Did we reach the end of our edge?
				if pixCur == nil {
					// Finish out the edge
					path.append(pixPrev.toCGPoint())
					totalPoints += 1
					break
				}
				
				// Set this pixel as visited
				imgMap[pixCur.y * widthPix + pixCur.x] |= UInt8(VisitedMask)
				
				// If this is our first neighbor along a new segment, start a new direction vector
				if vectorDir == .None {
					vectorDir = (pixCur.toCGVector() - vectorStart).normal
					continue
				}
				
				// Is the new pixel still on the current path segment (within tolerance?)
				var runningVector = (pixCur.toCGVector() - pixPrev.toCGVector()).normal
				totalError += 1 - runningVector.dot(vectorDir!)
				if totalError < EdgeAngleTolerance {
					// Nothing to do, keep looking for the end of the current segment
					continue
				}
				
				// Finish the current segment and start a new one
				totalPoints += 1
				path.append(pixPrev.toCGPoint())
				
				vectorStart = pixCur.toCGVector()
				vectorDir = .None
				totalError = 0
			}

			// Add our path to the array
			if path.count > 1 {
				pathArray.append(path)
			}
		}
		
		if totalPoints == 0 {
			NSLog("vectorizedImage found no paths for [" + (name ?? "unnamed") + "]")
			return .None
		}
		
		NSLog("vectorized %d points for [" + (name ?? "unnamed") + "]", totalPoints)
		
		if name != .None {
			vectorizedShapes[name!] = pathArray
			writePathArray(pathArray, name: name!)
		}
		
		return pathArray
	}
	
	class func writePathArray(pathArray: [[CGPoint]], name: String) {
		var pathArrayArr: [ [ [NSNumber] ] ] = []
		for path in pathArray {
			var pathArr: [ [NSNumber] ] = []
			for point in path {
				pathArr.append([ NSNumber(float: Float(point.x)), NSNumber(float: Float(point.y)) ])
			}
			
			pathArrayArr.append(pathArr)
		}

		let filename = name + ".vcache.plist"
		var paths = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, NSSearchPathDomainMask.UserDomainMask, true)
		var documentsDirectoryPath = paths[0] as String
		var filePath = documentsDirectoryPath.stringByAppendingPathComponent(filename)
		
		if !pathArrayArr._bridgeToObjectiveC().writeToFile(filePath, atomically: true) {
			NSLog("Error writing plist file: " + filePath)
		}
	}
	
	class func getPathArrayFilename(name: String) -> String {
		let filename = name + ".vcache.plist"
		var paths = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, NSSearchPathDomainMask.UserDomainMask, true)
		var documentsDirectoryPath = paths[0] as String
		return documentsDirectoryPath.stringByAppendingPathComponent(filename)
	}
	
	class func readPathArray(name: String) -> ([[CGPoint]])? {
		for forceEntry in forceRevectorization {
			if forceEntry == name {
				return .None
			}
		}

		let filePath = getPathArrayFilename(name)
		let pathArrayArr = NSArray(contentsOfFile: filePath)
		if pathArrayArr == .None || pathArrayArr.count == 0 {
			return .None
		}
		
		var pathArray: [[CGPoint]] = []
		for arr in pathArrayArr as [ [ [NSNumber] ] ] {
			var path: [CGPoint] = []
			for value in arr as [ [NSNumber] ] {
				var x = CGFloat(value[0].floatValue)
				var y = CGFloat(value[1].floatValue)
				path.append(CGPoint(x: x, y: y))
			}
			
			pathArray.append(path)
		}
		
		return pathArray
	}
}
