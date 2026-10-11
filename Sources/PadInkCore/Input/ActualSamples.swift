import Foundation
/// Values obtained from UIKit; no interpolation, prediction or sampling timer.
public struct ActualPoint:Equatable {
 public var timestamp:UInt64,x:Float,y:Float,pressure:Float,altitude:Float,azimuth:Float,flags:UInt8
 public init(timestamp:UInt64,x:Float,y:Float,pressure:Float,altitude:Float,azimuth:Float,flags:UInt8=0){self.timestamp=timestamp;self.x=x;self.y=y;self.pressure=pressure;self.altitude=altitude;self.azimuth=azimuth;self.flags=flags}
}
public struct PencilCapture {
 private var stroke:UInt64=0,sequence:UInt64=0
 private var last:ActualPoint?
 private var revision:UInt32=0
 public private(set) var active=false
 public init(){}
 public mutating func reset(){active=false;sequence=0;last=nil}
 public mutating func capture(_ actual:[ActualPoint],callback:PencilPhase,geometryGeneration:UInt32=1,record:((PencilSample,Int)->Void)?=nil)->[PencilSample]{
  guard !actual.isEmpty else{return []}
  if callback == .begin {guard !active else{return []};stroke+=1;sequence=0;last=nil;active=true;revision=geometryGeneration}
  guard active,revision==geometryGeneration else{return []}
  var result=[PencilSample]()
  for (i,p) in actual.enumerated(){
   let terminal=(callback == .end || callback == .cancel) && i==actual.count-1
   if let last {if p.timestamp<last.timestamp{continue};if p==last && !terminal{continue}}
   sequence+=1;let phase:PencilPhase=sequence==1 ? .begin:terminal ? callback:.move
   let sample=PencilSample(stroke:stroke,sequence:sequence,timestamp:p.timestamp,x:p.x,y:p.y,pressure:p.pressure,altitude:p.altitude,azimuth:p.azimuth,phase:phase,flags:p.flags,geometryGeneration:revision)
   result.append(sample);record?(sample,i);last=p
  }
  if callback == .end || callback == .cancel {active=false;last=nil}
  return result
 }
 /// A control cancellation at the last actual point, never a replayed movement.
 public mutating func cancel()->PencilSample? {
  guard active,let last else{return nil}
  return capture([last],callback:.cancel,geometryGeneration:revision).last
 }
}
