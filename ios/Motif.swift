import SwiftUI
struct MotifPoint: Codable { var x: Double; var y: Double
    func turned(_ n: Int) -> MotifPoint { switch n % 4 { case 1: return MotifPoint(x:1-y,y:x); case 2:return MotifPoint(x:1-x,y:1-y);case 3:return MotifPoint(x:y,y:1-x);default:return self } }
}
struct WallpaperMotif: Codable {
    var strokes: [[MotifPoint]] = []
    var pointCount: Int { strokes.reduce(0) { $0 + $1.count } }
    mutating func add(_ input: [MotifPoint]) {
        guard strokes.count < 60,pointCount < 3000,!input.isEmpty else { return }
        var points: [MotifPoint] = []
        for item in input { let p = MotifPoint(x:min(1,max(0,item.x)),y:min(1,max(0,item.y))); if points.last.map({ hypot($0.x-p.x,$0.y-p.y) >= 0.008 }) ?? true { points.append(p) } }
        if let end = input.last,let last = points.last, last.x != end.x || last.y != end.y { points.append(end) }
        if points.count == 1 { points.append(MotifPoint(x:min(1,points[0].x+0.002),y:points[0].y)) }
        let limited = Array(points.prefix(3000-pointCount)); if limited.count > 1 { strokes.append(limited) }
    }
    func fitted() -> WallpaperMotif {
        let points = strokes.flatMap { $0 }; guard let minX = points.map(\.x).min(),let minY = points.map(\.y).min(),let maxX = points.map(\.x).max(),let maxY = points.map(\.y).max() else { return self }
        let sx = maxX-minX,sy = maxY-minY, span = max(sx,sy,0.08)
        return WallpaperMotif(strokes:strokes.map { $0.map { MotifPoint(x:($0.x-minX+(span-sx)/2)/span,y:($0.y-minY+(span-sy)/2)/span) } })
    }
    static func read(_ raw: Data) -> WallpaperMotif { (try? JSONDecoder().decode(Self.self,from:raw)) ?? Self() }
}
struct MotifCanvas: View {
    let motif: WallpaperMotif
    var phase = 1.0
    var density = 1.0
    var weight = 2.0
    var color = Color.accentColor
    var body: some View { Canvas { context,size in
        let cell = max(32,120/density), fitted = motif.fitted()
        for row in 0...Int(size.height/cell) { for column in 0...Int(size.width/cell) {
            let turns = row % 2 == 0 ? (column % 2 == 0 ? 0 : 1) : (column % 2 == 0 ? 3 : 2)
            for stroke in fitted.strokes {
                var path = Path()
                for (index,point) in stroke.enumerated() { let p = point.turned(turns); let at = CGPoint(x:Double(column)*cell+p.x*cell,y:Double(row)*cell+p.y*cell); if index == 0 { path.move(to:at) } else { path.addLine(to:at) } }
                context.stroke(path.trimmedPath(from:0,to:phase),with:.color(color),style:StrokeStyle(lineWidth:weight,lineCap:.round,lineJoin:.round))
            }
        } }
    }.allowsHitTesting(false) }
}
struct MotifEditor: View {
    @AppStorage("backgroundMotif") private var stored = Data()
    @AppStorage("background") private var background = "classic"
    @State private var drawing: [MotifPoint] = []
    @State private var motif = WallpaperMotif()
    var body: some View { ScrollView { VStack(alignment:.leading,spacing:20) {
        Text("Нарисуйте узор пальцем. Он повторится на фоне с поворотом соседних плиток.").foregroundStyle(.secondary)
        GeometryReader { geometry in Canvas { context,size in
            for stroke in motif.strokes + [drawing] { var path = Path(); for (index,p) in stroke.enumerated() { let point = CGPoint(x:p.x*size.width,y:p.y*size.height); if index == 0 { path.move(to:point) } else { path.addLine(to:point) } }; context.stroke(path,with:.color(.accentColor),style:StrokeStyle(lineWidth:3,lineCap:.round)) }
        }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged { value in guard drawing.count < 3000 else { return }; drawing.append(MotifPoint(x:min(1,max(0,value.location.x/geometry.size.width)),y:min(1,max(0,value.location.y/geometry.size.height)))) }.onEnded { _ in motif.add(drawing); drawing = [] }) }.frame(height:300).background(.quaternary,in:RoundedRectangle(cornerRadius:24))
        HStack { Button("Отменить штрих") { if !motif.strokes.isEmpty { motif.strokes.removeLast() } }; Spacer(); Button("Очистить",role:.destructive) { motif = WallpaperMotif() } }
        Text("Предпросмотр").font(.headline)
        MotifCanvas(motif:motif).frame(height:200).background(.quaternary,in:RoundedRectangle(cornerRadius:24))
        Text("\(motif.strokes.count)/60 штрихов · \(motif.pointCount)/3000 точек").font(.caption)
        Button("Сохранить и применить") { stored = (try? JSONEncoder().encode(motif)) ?? Data(); background = "drawn" }.buttonStyle(.borderedProminent).disabled(motif.strokes.isEmpty)
    }.padding(20).padding(.bottom, 16) }.navigationTitle("Свой рисунок").onAppear { motif = WallpaperMotif.read(stored) } }
}
