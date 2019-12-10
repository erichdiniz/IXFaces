import UIKit
import AVFoundation
import Vision
import UIKit
import CoreML
import ImageIO
import SwiftSpinner
import VisualRecognition
import BMSCore


class FrameExtractorController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    @IBOutlet weak var cameraPreview: UIView!
    
    @IBOutlet weak var imageView: UIImageView!
    
    
    private var pulleyViewController: PulleyViewController!
    let defaultClassifierID = "connectors"
    var visualRecognitionClassifierID: String?
    var visualRecognition: VisualRecognition?
    
    var videoDataOutput: AVCaptureVideoDataOutput!
    var videoDataOutputQueue: DispatchQueue!
    var previewLayer:AVCaptureVideoPreviewLayer!
    var captureDevice : AVCaptureDevice!
    let session = AVCaptureSession()
    let context = CIContext()
//    var classification = ViewController()
    
    var isInitialized = false
    
    var classifiers: [ClassResult] = [] {
        didSet {
            isInitialized = true
        }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        imageView.isHidden = true

        view.addSubview(cameraPreview)
        self.setUpAVCapture()
        
        configureVisualRecognition()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCamera()
    }
    
    // To add the layer of your preview
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.previewLayer.frame = self.cameraPreview.layer.bounds
    }
    
    // To set the camera and its position to capture
    func setUpAVCapture() {
        session.sessionPreset = AVCaptureSession.Preset.vga640x480
        guard let device = AVCaptureDevice
            .default(AVCaptureDevice.DeviceType.builtInWideAngleCamera,
                     for: .video,
                     position: AVCaptureDevice.Position.front
            ) else {
                        return
        }
        captureDevice = device
        beginSession()
    }
    
    // Function to setup the beginning of the capture session
    func beginSession(){
        var deviceInput: AVCaptureDeviceInput!
        
        do {
            deviceInput = try AVCaptureDeviceInput(device: captureDevice)
            guard deviceInput != nil else {
                print("error: cant get deviceInput")
                return
            }
            
            if self.session.canAddInput(deviceInput){
                self.session.addInput(deviceInput)
            }
            
            videoDataOutput = AVCaptureVideoDataOutput()
            videoDataOutput.alwaysDiscardsLateVideoFrames=true
            videoDataOutputQueue = DispatchQueue(label: "VideoDataOutputQueue")
            videoDataOutput.setSampleBufferDelegate(self, queue:self.videoDataOutputQueue)
            
            if session.canAddOutput(self.videoDataOutput){
                session.addOutput(self.videoDataOutput)
            }
            
            videoDataOutput.connection(with: .video)?.isEnabled = true
            
            previewLayer = AVCaptureVideoPreviewLayer(session: self.session)
            previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
            
            let rootLayer :CALayer = self.cameraPreview.layer
            rootLayer.masksToBounds=true
            
            rootLayer.addSublayer(self.previewLayer)
            session.startRunning()
        } catch let error as NSError {
            deviceInput = nil
            print("error: \(error.localizedDescription)")
        }
    }
    
    // Function to capture the frames again and again
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // do stuff here
//        print("Got a frame")
        DispatchQueue.main.async { [unowned self] in
            guard let uiImage = self.imageFromSampleBuffer(sampleBuffer: sampleBuffer) else { return }
//            uiImage.transform = CGAffineTransform(rotationAngle: CGFloat.pi/2)
//            print(uiImage)
            self.displayImage( image: uiImage )
            self.classifyImage(for: uiImage, localThreshold: 0.1)
        }
        
    }
    
    // Function to process the buffer and return UIImage to be used
    func imageFromSampleBuffer(sampleBuffer : CMSampleBuffer) -> UIImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer, options: [.applyOrientationProperty:true])
        
        
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        
        return UIImage(cgImage: cgImage)

    }
    
    // To stop the session
    func stopCamera(){
        session.stopRunning()
        
    }

}

extension FrameExtractorController {
    func configureVisualRecognition() {
        // Retrieve BMSCredentials plist
        guard let contents = Bundle.main.path(forResource: "BMSCredentials", ofType: "plist"),
            let dictionary = NSDictionary(contentsOfFile: contents) else {
                
                showAlert(.missingBMSCredentialsPlist)
                return
        }
        
        // Set the Watson credentials for Visual Recognition service from the BMSCredentials.plist
        // If using IAM authentication
        guard let apiKey = dictionary["visualrecognitionApikey"] as? String else {
            self.showAlert(.missingCredentials)
            return
        }
        self.visualRecognition = VisualRecognition(version: "2018-03-15", apiKey: apiKey)
        
        // Retrive Classifiers, Update the local model or download if neccessary
        // If no classifiers exists remotely, try to use a local model.
        retrieveClassifiers(failure: retrieveClassifiersFailureHandler) { model in
            self.visualRecognition?.updateLocalModel(classifierID: model) { _, error in
                if let error = error {
                    self.failureHandler(error: error)
                } else {
                    SwiftSpinner.hide()
                }
            }
        }
    }
    
    // Retrieve available classifiers
    func retrieveClassifiers(failure: @escaping (Error) -> Void, success: @escaping (String) -> Void) {
        // Set verbose = true as a temporary fix for the sdk.
        self.visualRecognition?.listClassifiers(verbose: true) { response, error in
            if let error = error {
                self.retrieveClassifiersFailureHandler(error: error)
                return
            }
            guard let classifiers = response?.result?.classifiers else {
                self.showAlert(.noData)
                return
            }
            
            /// Check if the user created the connectors classifier
            /// If it doesn't exist use any one that exists
            var classifierID: String? = classifiers.first?.classifierID
            
            for classifier in classifiers where classifier.classifierID == self.defaultClassifierID {
                classifierID = classifier.classifierID
                break
            }
            
            if let classifier = classifierID {
                self.visualRecognitionClassifierID = classifier
                success(classifier)
            } else {
                failure(AppError.error("No classifiers exist. Please make sure to create a Visual Recognition classifier. Check the readme for more information."))
            }
        }
    }
    
    // Creates and displays default data
//    func configureDefaults() {
//        // Create default data
//        let defaults = [
//            ClassResult(className: "usb_male", score: 0.6, typeHierarchy: "/connector"),
//            ClassResult(className: "usbc_male", score: 0.5),
//            ClassResult(className: "thunderbolt_male", score: 0.11)
//        ]
//        
//        // Display data
//        displayResults(defaults)
//        displayImage(image: UIImage(named: "usb")!)
//    }
//    
    // Update local Core ML model failure handler
    func failureHandler(error: Error) {
        // Log Original Error
        print(error)
        // Show alert
        self.showAlert(.installingTrainingModel)
    }
    
    // Handler to attempt to use a local model
    func retrieveClassifiersFailureHandler(error: Error) {
        // Log Error
        print("Retrieving Classifiers Error:", error)
        print("Attempting to use a local Core ML model.")
        
        /// If a remote classifier does not exist, try to use a local one.
        guard let localModels = try? self.visualRecognition?.listLocalModels(),
            let classifierID = localModels?.first else {
                
                self.showAlert(.installingTrainingModel)
                return
        }
        
        // Update classifer
        print("Using local Core ML model:", classifierID)
        self.visualRecognitionClassifierID = classifierID
        
        // Hide Swift Spinner
        SwiftSpinner.hide()
    }
    
    // MARK: - Error Handling Methods
    
    // Method to show an alert with an alertTitle String and alertMessage String
    func showAlert(_ error: AppError) {
        // Log error
        print(error.description)
        // Hide spinner
        SwiftSpinner.hide()
        // If an alert is not currently being displayed
        if self.presentedViewController == nil {
            // Set alert properties
            let alert = UIAlertController(title: error.title, message: error.message, preferredStyle: .alert)
            // Add an action to the alert
            alert.addAction(UIAlertAction(title: "Dismiss", style: .default, handler: nil))
            // Show the alert
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    // MARK: - Pulley Library methods
    
    
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if let controller = segue.destination as? PulleyViewController {
            self.pulleyViewController = controller
        }
    }
    
    // MARK: - Display Methods
    
    // Convenience method for displaying image
    func displayImage(image: UIImage) {
        if let pulley = self.pulleyViewController {
            if let display = pulley.primaryContentViewController as? ImageDisplayViewController {
                display.image.contentMode = UIView.ContentMode.scaleAspectFit
                display.image.image = image
                
            }
        }
    }
    
    // Convenience method for pushing classification data to TableView
    func displayResults(_ classifications: [ClassResult]) {
            self.classifiers = classifications
            print(classifications[0].className)
            print(classifications[0].score)
        imageView.isHidden = false
        cameraPreview.isHidden = true
        
        if classifications[0].className != "" && classifications[0].score >= 0.60{
            let yourImage: UIImage = UIImage(named: "\(classifications[0].className)")!
           
//            let toImage = UIImage(named:"myname.png")
            
            UIView.transition(with: self.imageView,
                                      duration: 10,
                                      options: UIView.AnimationOptions.transitionCrossDissolve,
                                      animations: { self.imageView.image = yourImage },
                                      completion: nil)


        } else {
            imageView.isHidden = true
            cameraPreview.isHidden = false
        }
            self.dismiss(animated: false, completion: nil)
        
    }
    
    
    // Convenience method for pushing data to the TableView.
    func getTableController(run: (_ tableController: ResultsTableViewController, _ drawer: PulleyViewController) -> Void) {
        if let drawer = self.pulleyViewController {
            if let tableController = drawer.drawerContentViewController as? ResultsTableViewController {
                run(tableController, drawer)
                tableController.tableView.reloadData()
            }
        }
    }
    
    // MARK: - Image Classification
    
    // Method to classify the provided image returning classifiers meeting the provided threshold
    func classifyImage(for image: UIImage, localThreshold: Double = 0.0) {
        
        // Ensure VR is configured
        guard let vr = visualRecognition, let classifier = visualRecognitionClassifierID else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.showAlert(.error("Da um tempo ai meu consagrado, o modelo ta carregando xDDDD."))
            }
            return
        }
        
        // Classify image locally
        vr.classifyWithLocalModel(image: image, classifierIDs: [classifier], threshold: localThreshold) { response, error in
            if let error = error {
                print(error)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showAlert(.error("Failed to load model. Please ensure your model exists and has finished training."))
                }
                return
            }
            guard let classifiedImages = response else {
                self.showAlert(.noData)
                return
            }
            
            if classifiedImages.images.count > 0 && classifiedImages.images[0].classifiers.count > 0 {
                // Update UI on main thread
                DispatchQueue.main.async {
                    self.displayResults(classifiedImages.images[0].classifiers[0].classes)
//                    print(self.displayResults(classifiedImages.images[0].classifiers[0].classes))
                }
            }
        }
    }
}

fileprivate func convertFromUIImagePickerControllerInfoKeyDictionary(_ input: [UIImagePickerController.InfoKey: Any]) -> [String: Any] {
    return Dictionary(uniqueKeysWithValues: input.map {key, value in (key.rawValue, value)})
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertFromUIImagePickerControllerInfoKey(_ input: UIImagePickerController.InfoKey) -> String {
    return input.rawValue
}

