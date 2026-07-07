import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_drawing_board/flutter_drawing_board.dart';
import 'package:flutter_drawing_board/paint_contents.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'package:matting/matting.dart';


void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  static const String _modelAssetPath =
      'assets/models/birefnet_lite/model.onnx';
  static const String _modelFileName = 'birefnet_lite.onnx';

  Uint8List? image;

  MattingResult? mattingResult;

  Uint8List? get editImage => mattingResult?.data;

  Size imageSize = Size.zero;

  bool showGrid = false;

  Color? backgroundColor;
  Uint8List? backgroundImage;

  final _transformationController = TransformationController();

  bool showPaint = false;
  bool firstDraw = true;

  /// 描边
  bool showStroke = false;

  /// 距离描边
  bool showDistanceStroke = false;
  List<Path> distanceStrokePaths = <Path>[];

  /// 轮廓实心填充
  bool showContourFill = false;
  List<Path> contourPaths = <Path>[];
  int contourImgW = 0;
  int contourImgH = 0;
  double contourStrokeWidth = 8.0;
  bool contourDash = false;

  /// 绘制控制器
  final DrawingController _drawingController = DrawingController(
    config: DrawConfig(
      contentType: SimpleLine,
      color: Colors.red.withValues(alpha: 0.35),
      strokeJoin: StrokeJoin.round,
      strokeWidth: 20,
    ),
  );

  @override
  void initState() {
    super.initState();
  }

  @override
  dispose() {
    super.dispose();

    _drawingController.dispose();
  }

  /// 自适应最大尺寸
  Size fitMaxSize({required Size size, required Size maxSize}){
    if(size.width==0||size.height==0) return size;
    if(size.width==size.height) {
      if(maxSize.width>maxSize.height) return Size(maxSize.height, maxSize.height);
      return Size(maxSize.width, maxSize.width);
    }

    if(size.width/size.height > maxSize.width/maxSize.height){
      return Size(maxSize.width, maxSize.width/size.width*size.height);
    }
    return Size(maxSize.height/size.height*size.width, maxSize.height);
  }

  Future<File> _ensureModelFile() async {
    final Directory supportDirectory = await getApplicationSupportDirectory();
    final File modelFile = File('${supportDirectory.path}/$_modelFileName');
    if (await modelFile.exists()) {
      return modelFile;
    }

    final ByteData assetData = await rootBundle.load(_modelAssetPath);
    await modelFile.writeAsBytes(assetData.buffer.asUint8List(), flush: true);
    return modelFile;
  }

  Widget button({VoidCallback? onPressed, String title = ''}) {
    return InkWell(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey, width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(title, style: const TextStyle(fontSize: 14)),
      ),
    );
  }

  Widget button2({VoidCallback? onPressed, required IconData icon}) {
    return InkWell(
      onTap: onPressed,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10),
        child: Icon(icon, size: 22),
      ),
    );
  }

  void pickImage() async {
    final result = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (result == null) return;

    image = await result.readAsBytes();

    final decoded = img.decodeImage(image!);
    if (decoded == null) return;

    final imageWidth = decoded.width.toDouble();
    final imageHeight = decoded.height.toDouble();
    imageSize = Size(imageWidth, imageHeight);

    if (mounted) {
      setState(() {});
    }
  }

  /// 转换获取ui.Image
  Future<ui.Image> uiImageFromData(Uint8List imageData) async {
    final Completer<ui.Image> completer = Completer();
    ui.decodeImageFromList(imageData, (ui.Image image) {
      return completer.complete(image);
    });
    return completer.future;
  }

  void _onDoubleTap() {
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    if (currentScale != 1.0) {
      // 复原到初始状态
      _transformationController.value = Matrix4.identity();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Plugin example app')),
        floatingActionButton: FloatingActionButton(
          onPressed: () => pickImage(),
          child: const Icon(Icons.add),
        ),
        body: Container(
          margin: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          padding: const EdgeInsets.all(8),
          child: image == null
              ? null
              : Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                children: [
                  button(onPressed: () => cropImage(), title: '抠图'),
                  SizedBox(width: 10),
                  button(onPressed: () => onGrid(), title: '棋盘格'),
                  SizedBox(width: 10),
                  button(
                    onPressed: () => onBackgroundColor(),
                    title: '背景色',
                  ),
                  SizedBox(width: 10),
                  button(
                    onPressed: () => onBackgroundImage(),
                    title: '背景图',
                  ),
                ],
              ),
              SizedBox(height: 10),
              Row(
                children: [
                  button(onPressed: () => onPaint(), title: '画板'),
                  if (showPaint)
                    Row(
                      children: [
                        SizedBox(width: 10),
                        button2(
                          icon: Icons.brush,
                          onPressed: () => _drawingController
                              .setPaintContent(SimpleLine()),
                        ),
                        button2(
                          icon: Icons.cleaning_services,
                          onPressed: () => _drawingController
                              .setPaintContent(Eraser()),
                        ),
                        button2(
                          icon: Icons.undo,
                          onPressed: () => _drawingController.undo(),
                        ),
                        button2(
                          icon: Icons.redo,
                          onPressed: () => _drawingController.redo(),
                        ),
                        button2(
                          icon: Icons.save,
                          onPressed: () => savePaint(),
                        ),
                      ],
                    ),
                ],
              ),
              SizedBox(height: 10),
              if(!showPaint) Row(
                children: [
                  button(onPressed: () => onStroke(), title: '描边1'),
                  SizedBox(width: 10),
                  button(onPressed: () => onStroke2(), title: '描边2'),
                  SizedBox(width: 10),
                  button(onPressed: () => onStroke3(), title: '描边3'),
                  SizedBox(width: 10),
                  button(onPressed: () => onStroke4(), title: '描边4'),
                ],
              ),
              SizedBox(height: 10),
              Expanded(child: page()),
            ],
          ),
        ),
      ),
    );
  }

  Widget page() {
    return Center(
      child: LayoutBuilder(
        builder: (cont, cons){
          final imageDisplaySize = fitMaxSize(size: imageSize, maxSize: cons.biggest);
          return Container(
            width: imageDisplaySize.width,
            height: imageDisplaySize.height,
            color: Colors.blueAccent,
            child: showPaint? drawWidget() : editWidget(imageDisplaySize),
          );
        },
      ),
    );
  }

  Widget editWidget(Size size) {
    return GestureDetector(
      onDoubleTap: _onDoubleTap,
      child: InteractiveViewer(
        transformationController: _transformationController,
        scaleEnabled: true,
        minScale: 0.5,
        maxScale: 3.0,
        child: content(size),
      ),
    );
  }

  Widget content(Size size) {
    if (mattingResult == null) {
      return Image.memory(image!);
    }

    // 原图尺寸 -> 显示尺寸的缩放比例
    final double scaleX = size.width / imageSize.width;
    final double scaleY = size.height / imageSize.height;

    final double left = mattingResult!.x * scaleX;
    final double top = mattingResult!.y * scaleY;
    final double cropWidth = mattingResult!.width * scaleX;
    final double cropHeight = mattingResult!.height * scaleY;

    return ClipRRect(
      child: Stack(
        children: [
          if (showGrid)
            Positioned.fill(child: CustomPaint(painter: MattingCheckerboard())),
          if (backgroundImage != null)
            Positioned.fill(
              child: Image.memory(backgroundImage!, fit: BoxFit.cover),
            ),

          Positioned(
            left: left,
            top: top,
            width: cropWidth,
            height: cropHeight,
            child: Image.memory(editImage!),
          ),

          if (showContourFill && contourPaths.isNotEmpty)
            Positioned(
              left: left,
              top: top,
              width: cropWidth,
              height: cropHeight,
              child: CustomPaint(
                painter: MattingStroke(
                  paths: contourPaths,
                  imageWidth: contourImgW,
                  imageHeight: contourImgH,
                  color: Colors.blue,
                  lineWidth: contourStrokeWidth,
                  fill: showContourFill,
                ),
              ),
            ),


          // 轮廓描边
          if (showStroke && contourPaths.isNotEmpty)
            Positioned(
              left: left,
              top: top,
              width: cropWidth,
              height: cropHeight,
              child: CustomPaint(
                painter: MattingStroke(
                  paths: contourPaths,
                  imageWidth: contourImgW,
                  imageHeight: contourImgH,
                  lineWidth: contourStrokeWidth,
                  dash: contourDash,
                ),
              ),
            ),

          // 距离描边
          if (showDistanceStroke && distanceStrokePaths.isNotEmpty)
            Positioned(
              left: left,
              top: top,
              width: cropWidth,
              height: cropHeight,
              child: CustomPaint(
                painter: MattingStroke(
                  paths: distanceStrokePaths,
                  imageWidth: contourImgW,
                  imageHeight: contourImgH,
                  color: Colors.blue,
                  lineWidth: contourStrokeWidth,
                  dash: contourDash,
                ),
              ),
            ),


        ],
      ),
    );
  }

  Widget imageWidget() {
    return Container(color: backgroundColor, child: Image.memory(editImage!));
  }

  /// 画板
  Widget drawWidget() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        addImagePaint(constraints.biggest);
        return DrawingBoard(
          controller: _drawingController,
          background: SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: Image.memory(image!),
          ),
        );
      },
    );
  }

  void addImagePaint(Size size){
    if(!firstDraw) return;
    if(mattingResult!=null){
      final double boardScale = size.width / imageSize.width;
      _drawingController.addImageMattingResult(mattingResult!, boardScale);
    }
    firstDraw = false;
  }

  Widget drawBackgroundWidget() {
    if (backgroundColor != null) return ColoredBox(color: backgroundColor!);
    if (backgroundImage != null) return Image.memory(backgroundImage!);
    return Image.memory(image!);
  }

  ///
  Future<void> cropImage() async {
    if (image == null) return;
    _drawingController.clear();

    final modelFile = await _ensureModelFile();

    final mask = await Matting().runSmartCut(
      modelFile: modelFile,
      imageBytes: image!,
    );
    if (mask == null) return;

    mattingResult = await Matting.mergeImageContour(image!, mask);

    firstDraw = true;
    showPaint = true;
    showGrid = true;

    if (mounted) {
      setState(() {});
    }
  }

  void onGrid() {
    showGrid = !showGrid;
    if (mounted) {
      setState(() {});
    }
  }

  void onBackgroundColor() {
    if (backgroundColor == null) {
      backgroundColor =
      Colors.primaries[Random().nextInt(Colors.primaries.length)];
    } else {
      backgroundColor = null;
    }

    if (mounted) {
      setState(() {});
    }
  }

  void onBackgroundImage() async {
    if (backgroundImage == null) {
      final result = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (result == null) return;
      backgroundImage = await result.readAsBytes();
    } else {
      backgroundImage = null;
    }

    if (mounted) {
      setState(() {});
    }
  }

  void onPaint() async {
    showPaint = !showPaint;
    if (mounted) {
      setState(() {});
    }
  }

  /// 保存绘制结果：根据 paintContent 的区域，抠出原图对应的内容
  void savePaint() async {
    mattingResult = await _drawingController.getPaintAreaImageContour(image!);

    await refreshContourData();

    showPaint = false;

    if (mounted) {
      setState(() {});
    }
  }

  /// 刷新轮廓数据
  Future refreshContourData() async {
    if (editImage == null) return;
    final decoded = img.decodeImage(editImage!);
    if (decoded == null) return;
    contourPaths = MattingContour.extractFilteredContours(editImage!);
    print('轮廓数量 : ${contourPaths.length}');

    contourImgW = decoded.width;
    contourImgH = decoded.height;
  }

  /// 描边：从 editImage 提取轮廓并用 CustomPaint 绘制
  void onStroke() async {
    if (editImage == null) return;

    showStroke = true;
    contourStrokeWidth = 8.0;
    contourDash = false;
    showContourFill = false;
    showDistanceStroke = false;

    if (mounted) {
      setState(() {});
    }
  }

  /// 描边2：距离非透明区域 10px 的蓝色实线轮廓
  void onStroke2() async {
    if (editImage == null) return;

    showDistanceStroke = true;
    showStroke = false;
    showContourFill = false;
    contourDash = false;

    distanceStrokePaths = MattingContour.extractDistanceContours(editImage!,);

    print('外间隔轮廓数量 : ${distanceStrokePaths.length}');

    if (mounted) {
      setState(() {});
    }
  }

  /// 描边3：距离非透明区域 10px 的蓝色虚线轮廓
  void onStroke3() async {
    if (editImage == null) return;

    showDistanceStroke = true;
    showStroke = false;
    showContourFill = false;
    contourDash = true;

    distanceStrokePaths = MattingContour.extractDistanceContours(editImage!,);

    print('外间隔轮廓数量 : ${distanceStrokePaths.length}');

    if (mounted) {
      setState(() {});
    }
  }

  void onStroke4() async {
    if (editImage == null) return;

    showStroke = false;
    contourStrokeWidth = 8.0;
    contourDash = false;
    showContourFill = true;
    showDistanceStroke = false;

    if (mounted) {
      setState(() {});
    }
  }
}
