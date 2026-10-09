/// Desktop pets (denial-pet-v1): layer surfaces the user can drop on a
/// window's edge or corner, which the window then carries.
///
/// The compositor runs a pet's drag from the user's own press and keeps
/// everything but the kind of hold from the pet's client. The shell decides
/// which window holds a dragged pet, through the selected [ShellPetHolds],
/// draws a held pet with its window, with what it casts there through the
/// selected [ShellPetShadows], and reports how fast it moves on screen.
library;

export 'src/models/denial_pet.dart'
    show DenialPet, DenialPetHold, DenialWindowHold;
export 'src/pets/pet_holds.dart';
export 'src/pets/pet_shadows.dart';
