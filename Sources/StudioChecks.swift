import Cocoa
import SwiftUI

func runStudioChecks() {
    let red=RGB(red:1,green:0,blue:0),blue=RGB(red:0,green:0,blue:1)
    var under=StudioLayer(effect:.solid);under.colors=[red]
    var above=StudioLayer(effect:.solid,mask:[22]);above.colors=[blue]
    var preset=StudioPreset(layers:[above,under])
    var frame=StudioRenderer.render(preset,time:0,hits:[])
    precondition(frame[22] == blue && frame[23] == red && frame[5] == StudioRenderer.black)
    preset.layers[0].opacity=0.5
    frame=StudioRenderer.render(preset,time:0,hits:[])
    precondition(frame[22] == RGB(red:0.5,green:0,blue:0.5))
    let group=StudioGroup();preset.groups=[group];preset.layers[0].group=group.id;preset.groups[0].enabled=false
    precondition(StudioRenderer.render(preset,time:0,hits:[])[22] == red)
    preset.layers[0].group=nil;preset.layers[0].enabled=false
    precondition(StudioRenderer.render(preset,time:0,hits:[])[22] == red)
    let migrated=StudioPreset.migrated((0..<24).map { $0 == 22 ? blue : red })
    precondition(migrated.valid && StudioRenderer.render(migrated,time:0,hits:[])[22] == blue)
    precondition(try! JSONDecoder().decode(StudioPreset.self,from:JSONEncoder().encode(migrated)) == migrated)
    precondition(StudioEffect.referenceCases == [.off,.solid,.wave,.spectrum,.reactive,.breathing,.starlight,.ripple,.wheel])
    precondition(StudioEffect.extraCases == [.fire])
    precondition(Set(StudioEffect.referenceCases+StudioEffect.extraCases) == Set(StudioEffect.allCases))
    let off=StudioLayer(effect:.off)
    precondition(!off.effect.animated && StudioRenderer.render(StudioPreset(layers:[off,under]),time:1,hits:[]).allSatisfy {$0 == StudioRenderer.black})
    let wheel=StudioLayer(effect:.wheel)
    let wheelA=StudioRenderer.render(StudioPreset(layers:[wheel]),time:0,hits:[])
    let wheelB=StudioRenderer.render(StudioPreset(layers:[wheel]),time:0.75,hits:[])
    precondition(wheelA != wheelB && wheelA[0] != wheelA[4])
    precondition(wheelA[5] == StudioRenderer.black && wheelA[22].valid && wheelA[23].valid)
    precondition(try! JSONDecoder().decode(StudioLayer.self,from:JSONEncoder().encode(wheel)).effect == .wheel)
    for effect in StudioEffect.allCases {
        var layer=StudioLayer(effect:effect)
        layer.colors=[red,blue]
        for random in [false,true] {
            layer.random=random
            let p=StudioPreset(layers:[layer])
            for t in [0.0,0.1,0.75,2.5,10.0,10000.0] {
                let f=StudioRenderer.render(p,time:t,hits:[LightingHit(index:22,time:max(0,t-0.1))],brightness:0.6)
                precondition(f.count == 24 && f.allSatisfy(\.valid))
                precondition(f.allSatisfy {$0.red <= 0.6 && $0.green <= 0.6 && $0.blue <= 0.6})
            }
        }
    }
    var reactive=StudioLayer(effect:.reactive);reactive.colors=[blue];reactive.duration=2
    preset=StudioPreset(layers:[reactive,under])
    precondition(StudioRenderer.render(preset,time:0,hits:[])[22] == red)
    frame=StudioRenderer.render(preset,time:1,hits:[LightingHit(index:22,time:0)])
    precondition(frame[22] == RGB(red:0,green:0,blue:0.5) && frame[23] == red)
    precondition(StudioRenderer.render(preset,time:3,hits:[LightingHit(index:22,time:0)])[22] == red)
    var timed=above;timed.delay=1;timed.repeatCount=1;timed.duration=2
    preset=StudioPreset(layers:[timed,under])
    precondition(StudioRenderer.render(preset,time:0,hits:[])[22] == red)
    precondition(StudioRenderer.render(preset,time:1,hits:[])[22] == blue)
    precondition(StudioRenderer.render(preset,time:3,hits:[])[22] == red)
    timed.startOnKey=true;preset.layers[0]=timed
    precondition(StudioRenderer.render(preset,time:2,hits:[])[22] == red)
    precondition(StudioRenderer.render(preset,time:2,hits:[LightingHit(index:22,time:1)])[22] == blue)
    precondition(StudioRenderer.render(StudioPreset(layers:[reactive]),time:0,hits:[LightingHit(index:22,time:1)]).allSatisfy(\.valid))
    precondition(LightingInput.index(page:7,usage:44) == 23 && LightingInput.index(page:9,usage:3) == 22)
    precondition(LightingInput.index(page:7,usage:30) == 0 && LightingInput.index(page:7,usage:6) == 21)
    precondition(LightingInput.index(page:7,usage:999) == nil)
    let c=LightController(loadProfile:false)
    c.options.quick.duration=12;c.options.quick.speed=0.5
    c.selectCustomCycle()
    precondition(c.options.quick.effect == .spectrum && c.options.quick.spectrumPalette && c.options.quick.colors.count >= 2)
    precondition(c.options.quick.duration == 12 && c.options.quick.speed == 0.5)
    c.selectedLights=[22];c.addLayer(.solid)
    let id=c.selectedLayerID!
    c.editLayer(id) {$0.colors=[blue]}
    let edited=c.draftPreset
    c.undoStudio();precondition(c.selectedLayer?.colors != [blue])
    c.redoStudio();precondition(c.draftPreset == edited)
    c.duplicateLayer();precondition(c.draftPreset.layers[0].id != id && c.draftPreset.layers[0].colors == [blue])
    c.deleteLayer();precondition(c.selectedLayerID == id)
    c.selectedLights=[0,1,2];c.applySelection();precondition(Set(c.selectedLayer!.mask) == [0,1,2])
    c.selectedLights=[1];c.eraseSelection();precondition(Set(c.selectedLayer!.mask) == [0,2])
    c.selectionMode="add";c.chooseLights([22]);precondition(c.selectedLights == [1,22])
    c.selectionMode="subtract";c.chooseLights([1]);precondition(c.selectedLights == [22])
    c.addGroup();precondition(c.selectedLayer?.group == c.draftPreset.groups.last?.id)
    let groupID=c.draftPreset.groups.last!.id;c.deleteGroup(groupID);precondition(c.selectedLayer?.group == nil)
    c.options.enabled=false;precondition(c.renderedFrame(elapsed:0).matrix.allSatisfy {$0 == StudioRenderer.black})
    c.options.enabled=true;c.displayOff=true
    precondition(c.renderedFrame(elapsed:0).matrix.allSatisfy {$0 == StudioRenderer.black})
    c.options.offWhenDisplayOff=false;precondition(c.renderedFrame(elapsed:0).matrix[0] != StudioRenderer.black)
    let old=LightProfile(red:1,green:0,blue:0,effect:.spectrum,cycleColors:[red,blue],cycleSeconds:12,customCycle:true)
    c.displayOff=false;c.loadStudio(old)
    precondition(c.options.quick.spectrumPalette && c.options.quick.colors == [red,blue])
    precondition(c.renderedFrame(elapsed:3).matrix[0] == RGB(red:0.5,green:0,blue:0.5))
    var bad=preset;bad.layers[0].mask=[24];precondition(!bad.valid)
    bad=preset;bad.layers[0].group=UUID();precondition(!bad.valid)
    bad=preset;bad.layers[0].speed = .nan;precondition(!bad.valid)
    var workspace=LightingWorkspace.initial(Array(repeating:red,count:24));precondition(workspace.valid)
    workspace.selected=UUID();precondition(!workspace.valid)
    // Retained inspector callback cannot target another layer after deletion.
    let view=EffectProperties(c:c,layerID:id),binding=view.color(0)
    c.deleteLayer();let after=c.draftPreset
    binding.wrappedValue = .green
    precondition(c.draftPreset == after)
    let temporary=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("tartarus-studio-check-"+UUID().uuidString,isDirectory:true)
    defer { try? FileManager.default.removeItem(at:temporary) }
    let savedController=LightController(loadProfile:false,profileURL:temporary.appendingPathComponent("lights.json"))
    savedController.selectedLights=[22];savedController.addLayer(.ripple)
    precondition(savedController.studioDirty)
    let didSave=savedController.saveStudio()
    if !didSave { fputs("Studio persistence check failed: \(savedController.status); valid=\(savedController.draftPreset.valid); path=\(savedController.path.path)\n",stderr) }
    precondition(didSave && !savedController.studioDirty)
    let loaded=LightController(loadProfile:false,profileURL:savedController.path);loaded.load()
    precondition(loaded.workspace == savedController.workspace && loaded.draftPreset == savedController.draftPreset)
    savedController.newPreset(duplicate:true);precondition(savedController.workspace.presets.count == 2)
    savedController.deletePreset();precondition(savedController.workspace.presets.count == 1)
    let invalidPath=temporary.appendingPathComponent("blocked")
    try! Data([0]).write(to:invalidPath)
    let blocked=LightController(loadProfile:false,profileURL:invalidPath.appendingPathComponent("lights.json"))
    blocked.addLayer(.fire)
    precondition(!blocked.saveStudio() && blocked.studioDirty)
    blocked.newPreset();precondition(blocked.workspace.presets.count == 1)
    print("PASS: reference effect catalogue, Off/Wheel, custom-cycle entry, ten lighting renderers, compositing, groups, playback, legacy migration, brightness, input coordinates, editor history and stale inspector bindings. No device commands; persistence checks use a temporary test folder.")
}
