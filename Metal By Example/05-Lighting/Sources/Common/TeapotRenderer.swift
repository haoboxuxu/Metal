import Metal
import MetalKit
import ModelIO
import simd

extension TeapotRenderer {
    private struct Uniforms {
        var modelViewProjectionMatrix: float4x4
        var modelViewMatrix: float4x4
        var normalMatrix: float3x3
    }
    
    enum Error: Swift.Error {
        case failedToCreateMetalDevice
        case failedToCreateMetalCommandQueue(device: MTLDevice)
        case failedToCreateMetalLibrary(device: MTLDevice)
        case failedToCreateShaderFunction(name: String)
        case failedToCreateDepthStencilState(device: MTLDevice)
        case failedToFoundFile(name: String)
        case failedToCreateMetalBuffer(device: MTLDevice)
    }
}

class TeapotRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let state: (render: MTLRenderPipelineState, depth: MTLDepthStencilState)
    private let uniformsBuffer: MTLBuffer
    private let meshes: [MTKMesh]
    private var (time, rotationX, rotationY): (Float, Float, Float) = (0,0,0)
    
    init(view: MTKView) throws {
        // Create GPU representation (MTLDevice) and Command Queue.
        guard let device = MTLCreateSystemDefaultDevice() else { throw Error.failedToCreateMetalDevice }
        guard let commandQueue = device.makeCommandQueue() else { throw Error.failedToCreateMetalCommandQueue(device: device) }
        (self.device, self.commandQueue) = (device, commandQueue)
        
        // Setup the MTKView.
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.depthStencilPixelFormat = .depth32Float
        
        // Initialize the library and respective metal functions.
        let functionName: (vertex: String, fragment: String) = ("main_vertex", "main_fragment")
        guard let library = device.makeDefaultLibrary() else { throw Error.failedToCreateMetalLibrary(device: device) }
        guard let vertexFunction = library.makeFunction(name: functionName.vertex) else { throw Error.failedToCreateShaderFunction(name: functionName.vertex) }
        guard let fragmentFunction = library.makeFunction(name: functionName.fragment) else { throw Error.failedToCreateShaderFunction(name: functionName.fragment) }
        
        // Define both states (render and depth-stencil).
        let renderPipelineDescriptor = MTLRenderPipelineDescriptor().set { (pipeline) in
            pipeline.vertexFunction = vertexFunction
            pipeline.vertexDescriptor = MTLVertexDescriptor().set {
                $0.attributes[0].setUp { (attribute) in
                    attribute.bufferIndex = 0
                    attribute.offset = 0
                    attribute.format = .float3
                }
                $0.attributes[1].setUp { (attribute) in
                    attribute.bufferIndex = 0
                    attribute.offset = MemoryLayout<Float>.stride * 3
                    attribute.format = .float4
                }
                $0.layouts[0].stride = MemoryLayout<Float>.stride * 7
            }
            
            pipeline.fragmentFunction = fragmentFunction
            pipeline.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        }
        
        let depthStencilStateDescriptor = MTLDepthStencilDescriptor().set { (state) in
            state.depthCompareFunction = .less
            state.isDepthWriteEnabled = true
        }

        let renderPipelineState = try device.makeRenderPipelineState(descriptor: renderPipelineDescriptor)
        guard let depthStencilState = device.makeDepthStencilState(descriptor: depthStencilStateDescriptor) else { throw Error.failedToCreateDepthStencilState(device: device) }
        self.state = (renderPipelineState, depthStencilState)
        
        // Load 3D file
        let file: (name: String, `extension`: String) = ("teapot", "obj")
        guard let url = Bundle.main.url(forResource: file.name, withExtension: file.`extension`) else { throw Error.failedToFoundFile(name: "\(file.name).\(file.`extension`)") }
        
        let modelDescriptor = MTKModelIOVertexDescriptorFromMetal(renderPipelineDescriptor.vertexDescriptor!).set {
            ($0.attributes[0] as! MDLVertexAttribute).name = MDLVertexAttributePosition
            ($0.attributes[1] as! MDLVertexAttribute).name = MDLVertexAttributeNormal
        }
        let asset = MDLAsset(url: url, vertexDescriptor: modelDescriptor, bufferAllocator: MTKMeshBufferAllocator(device: device))
        self.meshes = try MTKMesh.newMeshes(from: asset, device: device, sourceMeshes: nil)
		
        // Create buffers used in the shader
        guard let uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride) else { throw Error.failedToCreateMetalBuffer(device: device) }
        uniformBuffer.label = "me.dehesa.metal.buffers.uniform"
        self.uniformsBuffer = uniformBuffer
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        
    }
    
    func draw(in view: MTKView) {
        guard let mesh = meshes.first,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }
        
        descriptor.setUp {
            $0.colorAttachments[0].texture = drawable.texture
            $0.colorAttachments[0].loadAction = .clear
            $0.colorAttachments[0].clearColor = MTLClearColorMake(0.5, 0.5, 0.5, 1)
        }
        
        guard let commandBuffer = self.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        
        let drawableSize = drawable.layer.drawableSize.float2
        updateUniforms(drawableSize: drawableSize, duration: Float(1.0 / 60.0))
        
        do {
            encoder.setRenderPipelineState(self.state.render)
            encoder.setDepthStencilState(self.state.depth)
            encoder.setCullMode(.back)
            encoder.setFrontFacing(.counterClockwise)
            
            let vertexBuffer = mesh.vertexBuffers[0]
            encoder.setVertexBuffer(vertexBuffer.buffer, offset: vertexBuffer.offset, index: 0)
            encoder.setVertexBuffer(self.uniformsBuffer, offset: 0, index: 1)
            
            guard let submesh = mesh.submeshes.first else { fatalError("Submesh not found.") }
            encoder.drawIndexedPrimitives(type: submesh.primitiveType, indexCount: submesh.indexCount, indexType: submesh.indexType, indexBuffer: submesh.indexBuffer.buffer, indexBufferOffset: submesh.indexBuffer.offset)
            
            encoder.endEncoding()
        }
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    private func updateUniforms(drawableSize size: float2, duration: Float) {
        self.time += duration
        self.rotationX += duration * (.𝝉 / 4.0)
        self.rotationY += duration * (.𝝉 / 6.0)
        
        let scaleFactor: Float = 1
        let xRotMatrix = float4x4(rotate: float3(1, 0, 0), angle: self.rotationX)
        let yRotMatrix = float4x4(rotate: float3(0, 1, 0), angle: self.rotationX)
        let scaleMatrix = float4x4(scale: scaleFactor)
        
        let modelMatrix = (xRotMatrix * yRotMatrix) * scaleMatrix
        let viewMatrix = float4x4(translate: [0, 0, -1.5])
        let projectionMatrix = float4x4(perspectiveWithAspect: size.x/size.y, fovy: .𝝉/5, near: 0.1, far: 100)
        
        let modelViewMatrix = viewMatrix * modelMatrix
        let modelViewProjectionMatrix = projectionMatrix * modelViewMatrix
        let normalMatrix: float3x3 = { (m: float4x4) in
            let x = m.columns.0.xyz
            let y = m.columns.1.xyz
            let z = m.columns.2.xyz
            return float3x3(x, y, z)
        }(modelViewMatrix)
        
        var uni = Uniforms(modelViewProjectionMatrix: modelViewProjectionMatrix, modelViewMatrix: modelViewMatrix, normalMatrix: normalMatrix)
        memcpy(uniformsBuffer.contents(), &uni, MemoryLayout<Uniforms>.size)
    }
}