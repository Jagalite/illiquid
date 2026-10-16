import Observation
@Observable final class Model {
  var value: Int = 0 { didSet { callbacks += 1 } }
  @ObservationIgnored var callbacks = 0
}
let model = Model(); model.value = 0; print(model.callbacks)
